import Foundation
import LlamaSwift

public class LlamaContext {
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    
    public init(modelPath: String) throws {
        llama_backend_init()
        
        var modelParams = llama_model_default_params()
        // Enable Metal GPU offloading (offload all layers)
        modelParams.n_gpu_layers = 99
        
        guard let model = llama_load_model_from_file(modelPath.cString(using: .utf8), modelParams) else {
            throw NSError(domain: "LlamaError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to load model from \(modelPath)"])
        }
        
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = 2048 // 2K context window is plenty for medical reports
        ctxParams.n_threads = UInt32(max(1, ProcessInfo.processInfo.processorCount - 1))
        
        guard let context = llama_new_context_with_model(model, ctxParams) else {
            llama_free_model(model)
            throw NSError(domain: "LlamaError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create context"])
        }
        
        self.model = model
        self.context = context
    }
    
    public func predict(prompt: String, maxTokens: Int = 1000) -> String {
        guard let context = context, let model = model else { return "" }
        
        // Very basic synchronous prediction implementation
        // For production, you'd want streaming generation, but this gets us started
        
        // 1. Tokenize prompt
        var tokens = [llama_token](repeating: 0, count: Int(llama_n_ctx(context)))
        let n_tokens = llama_tokenize(model, prompt, Int32(prompt.count), &tokens, Int32(tokens.count), true, true)
        
        guard n_tokens > 0 else { return "" }
        
        // 2. Evaluate prompt
        var batch = llama_batch_get_one(&tokens, n_tokens)
        if llama_decode(context, batch) != 0 {
            return ""
        }
        
        var result = ""
        var n_cur = n_tokens
        
        // 3. Generate loop
        while n_cur <= n_tokens + Int32(maxTokens) {
            // Get logits and sample next token
            let logits = llama_get_logits_ith(context, batch.n_tokens - 1)
            let n_vocab = llama_n_vocab(model)
            
            var candidates = [llama_token_data]()
            for token_id in 0..<n_vocab {
                candidates.append(llama_token_data(id: token_id, logit: logits?[Int(token_id)] ?? 0.0, p: 0.0))
            }
            
            var candidates_p = llama_token_data_array(data: &candidates, size: candidates.count, sorted: false)
            
            // Basic greedy sampling for structured format consistency
            let next_token = llama_sample_token_greedy(context, &candidates_p)
            
            if next_token == llama_token_eos(model) {
                break
            }
            
            // Convert token to string
            var buf = [CChar](repeating: 0, count: 32)
            llama_token_to_piece(model, next_token, &buf, Int32(buf.count), 0, true)
            let piece = String(cString: buf)
            
            result += piece
            
            // Prepare next batch
            batch = llama_batch_get_one(&next_token, 1)
            if llama_decode(context, batch) != 0 {
                break
            }
            
            n_cur += 1
        }
        
        return result
    }
    
    deinit {
        if let context = context { llama_free(context) }
        if let model = model { llama_free_model(model) }
        llama_backend_free()
    }
}
