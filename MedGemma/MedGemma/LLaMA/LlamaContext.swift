import Foundation
import llama

/// Swift wrapper around llama.cpp's text-generation pipeline.
///
/// One instance loads a single GGUF model into Metal GPU memory, builds a
/// reusable sampler chain (penalties → top-k → top-p → temperature → dist),
/// and exposes a streaming `predict` that yields token pieces as they're
/// generated.
///
/// `@unchecked Sendable` because the underlying llama.cpp pointers are not
/// Sendable, but we serialize all access through a single detached task per
/// call. Don't call `predict` concurrently on the same instance.
public final class LlamaContext: @unchecked Sendable {
    private let model: OpaquePointer
    private let vocab: OpaquePointer
    private let context: OpaquePointer
    private let sampler: UnsafeMutablePointer<llama_sampler>

    public init(modelPath: String) throws {
        llama_backend_init()

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99 // offload everything to Metal

        guard let model = llama_load_model_from_file(modelPath.cString(using: .utf8), modelParams) else {
            throw NSError(
                domain: "LlamaError",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to load model from \(modelPath)"]
            )
        }

        // llama.cpp b7484 split the vocab off the model — tokenize/token_to_piece/
        // token_is_eog now take a `llama_vocab *`, not a `llama_model *`. Both come
        // through Swift as OpaquePointer, so passing the wrong one type-checks but
        // EXC_BAD_ACCESS's at runtime when llama.cpp dereferences the model
        // pointer expecting vocab struct layout. Cache the vocab once at init.
        guard let vocab = llama_model_get_vocab(model) else {
            llama_free_model(model)
            throw NSError(
                domain: "LlamaError",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to extract vocab from model"]
            )
        }

        var ctxParams = llama_context_default_params()
        // 4096 is enough for multi-page lab reports without the prompt
        // silently overflowing (which manifested as blank reports — the
        // 2048 default was getting exceeded as soon as the user uploaded
        // 2+ pages worth of OCR text plus our system prompt + output
        // budget). 4096 roughly doubles KV cache memory but still fits
        // comfortably alongside the 4B model on iPhones with 6GB+ RAM.
        ctxParams.n_ctx = 4096
        ctxParams.n_threads = Int32(max(1, ProcessInfo.processInfo.processorCount - 1))
        ctxParams.n_threads_batch = ctxParams.n_threads

        guard let context = llama_new_context_with_model(model, ctxParams) else {
            llama_free_model(model)
            throw NSError(
                domain: "LlamaError",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create llama context"]
            )
        }

        // Build the sampler chain. Order matters: penalties first (raw logits),
        // then truncate to top-K, then nucleus, then temperature softening,
        // then the final dist sampler that actually picks a token.
        let sparams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(sparams) else {
            llama_free(context)
            llama_free_model(model)
            throw NSError(
                domain: "LlamaError",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create sampler chain"]
            )
        }

        // Repeat-penalty 1.1 over the last 64 tokens. Discourages "elevated.
        // elevated. elevated." loops without distorting facts.
        llama_sampler_chain_add(sampler, llama_sampler_init_penalties(
            64,   // penalty_last_n
            1.1,  // penalty_repeat
            0.0,  // penalty_freq
            0.0   // penalty_present
        ))
        // Cap to top 40 candidates — drops the long tail of nonsense tokens.
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
        // Nucleus: keep tokens whose cumulative prob ≤ 0.9.
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.9, 1))
        // Temperature 0.4: mostly deterministic, slight phrasing variation.
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.4))
        // Final dist sampler picks the actual token from the shaped distribution.
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED))

        self.model = model
        self.vocab = vocab
        self.context = context
        self.sampler = sampler
    }

    /// Streams generated token pieces. Each yielded String is the next chunk
    /// (usually a sub-word) — concatenate them to get the full response.
    ///
    /// Each call resets the KV cache and sampler state, so calls are
    /// independent. Cancelling the consuming Task stops generation at the
    /// next loop iteration.
    public func predict(prompt: String, maxTokens: Int = 1000) -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) { [self] in
                self.runPredict(prompt: prompt, maxTokens: maxTokens) { piece in
                    continuation.yield(piece)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func runPredict(prompt: String, maxTokens: Int, onToken: (String) -> Void) {
        // Each call is independent — clear residual state from prior generations.
        // llama.cpp b7484 replaced llama_kv_cache_clear with the unified memory API.
        llama_memory_clear(llama_get_memory(context), true)
        llama_sampler_reset(sampler)

        let promptCStr = Array(prompt.utf8CString)
        let nCtx = Int32(llama_n_ctx(context))
        var promptTokens = [llama_token](repeating: 0, count: Int(nCtx))
        let nPromptTokens = llama_tokenize(
            vocab,
            promptCStr,
            Int32(promptCStr.count - 1), // exclude trailing NUL
            &promptTokens,
            nCtx,
            true,  // add_bos
            true   // parse_special — required for Gemma <start_of_turn> markers
        )
        // llama_tokenize returns a negative number when the prompt would
        // overflow n_ctx — we used to silently `return` here which made
        // multi-page scans look like the model gave up. Log the failure
        // so the upstream caller can detect "empty stream" and surface
        // a clear error to the user.
        guard nPromptTokens > 0 else {
            print("[LlamaContext] Prompt tokenize failed (returned \(nPromptTokens), n_ctx=\(nCtx)). Most likely the prompt is too long.")
            return
        }
        // Log successful tokenization so we can correlate prompt size with
        // any downstream ggml_abort / Metal allocation issues. The
        // available budget is n_ctx − maxTokens; if this number is close
        // to that, we're flirting with an overflow during decode.
        print("[LlamaContext] Tokenize OK: \(nPromptTokens) tokens (n_ctx=\(nCtx), output budget=\(maxTokens), headroom=\(Int(nCtx) - Int(nPromptTokens) - maxTokens))")

        // Decode the entire prompt in one batch to populate the KV cache.
        var promptBatch = llama_batch_get_one(&promptTokens, nPromptTokens)
        guard llama_decode(context, promptBatch) == 0 else { return }

        // Generation loop. The new sampler API hides the candidates buffer:
        // llama_sampler_sample reads logits from the context internally,
        // applies the chain, and returns a token id. No per-token allocation
        // of [llama_token_data] like the old greedy path required.
        var generated = 0
        while generated < maxTokens {
            if Task.isCancelled { return }

            let nextToken = llama_sampler_sample(sampler, context, -1)
            if llama_token_is_eog(vocab, nextToken) { return }

            llama_sampler_accept(sampler, nextToken)

            // Convert the token id to its UTF-8 piece. 128 chars covers any
            // single sub-word in Gemma's vocab with room to spare.
            var buf = [CChar](repeating: 0, count: 128)
            let nChars = llama_token_to_piece(vocab, nextToken, &buf, Int32(buf.count), 0, true)
            if nChars > 0 {
                buf[Int(nChars)] = 0
                let piece = String(cString: buf)
                if !piece.isEmpty { onToken(piece) }
            }

            // Extend the KV cache by one token so the next sample sees this one.
            var nextTokenVar = nextToken
            var stepBatch = llama_batch_get_one(&nextTokenVar, 1)
            guard llama_decode(context, stepBatch) == 0 else { return }

            generated += 1
        }
    }

    deinit {
        llama_sampler_free(sampler)
        llama_free(context)
        llama_free_model(model)
        llama_backend_free()
    }
}
