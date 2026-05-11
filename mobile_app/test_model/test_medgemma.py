import os
import torch
from transformers import AutoTokenizer, AutoModelForCausalLM

# Use Apple's Metal Performance Shaders (MPS) for GPU acceleration on M-series chips
device = "mps" if torch.backends.mps.is_available() else "cpu"

# The official Google MedGemma 4B instruction-tuned model
MODEL_ID = "google/medgemma-4b-it"

def test_model():
    print(f"🧠 Loading MedGemma into Mac's GPU ({device.upper()})...")
    print("If you get a Hugging Face Token error, you need to login first using: `huggingface-cli login`")
    
    try:
        # Load the tokenizer
        tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)
        
        # Load the model directly into Metal GPU in half-precision (bfloat16) to fit in memory
        model = AutoModelForCausalLM.from_pretrained(
            MODEL_ID,
            torch_dtype=torch.bfloat16,
            device_map=device
        )
    except Exception as e:
        print(f"\n❌ Failed to load model. Did you authenticate with Hugging Face?")
        print(f"Error details: {e}")
        return
        
    print("\n🚀 Model loaded successfully!\n")
    
    # We construct the prompt using the Gemma instruct format.
    medical_prompt = """<start_of_turn>user
You are an empathetic, highly trained medical assistant.
A patient has just received their lab results. Their HbA1c is 7.2% and their fasting glucose is 135 mg/dL. They also have a history of hypertension. 

Explain these clinical results logically in very simple, reassuring terms to a patient with no medical background. Provide actionable but gentle lifestyle advice. Do not diagnose.
<end_of_turn>
<start_of_turn>model
"""
    
    print("--------------------------------------------------")
    print("📝 THE PROMPT (Input):")
    print("Patient Data: HbA1c 7.2%, Fasting Glucose 135 mg/dL, History of Hypertension")
    print("Task: Explain simply and empathetically.")
    print("--------------------------------------------------\n")
    
    print(f"⚙️  Generating response on {device.upper()}...")
    
    inputs = tokenizer(medical_prompt, return_tensors="pt").to(device)
    
    # Run the inference
    outputs = model.generate(
        **inputs,
        max_new_tokens=350,
        temperature=0.3,
        do_sample=True,
    )
    
    # Decode the response and remove the prompt from the output
    response = tokenizer.decode(outputs[0], skip_special_tokens=False)
    response_clean = response.split("<start_of_turn>model\n")[-1].replace("<end_of_turn>", "")
    
    print("\n--------------------------------------------------")
    print("🩺 MEDGEMMA'S RESPONSE (Output):")
    print(response_clean.strip())
    print("--------------------------------------------------\n")
    print("✅ Test complete! If you liked this response, this is exactly what will run on the iPhone.")

if __name__ == "__main__":
    test_model()
