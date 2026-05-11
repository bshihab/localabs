import os
import sys
import torch
from transformers import AutoTokenizer, AutoModelForCausalLM
import Quartz
import Vision
from Foundation import NSURL

# --- 1. THE EYES: Apple Vision OCR ---
def extract_text(image_path):
    print(f"👁️  [Step 1] Booting Apple Vision to scan '{os.path.basename(image_path)}'...")
    input_url = NSURL.fileURLWithPath_(image_path)
    handler = Vision.VNImageRequestHandler.alloc().initWithURL_options_(input_url, None)
    extracted_text_lines = []
    
    def completion_handler(request, error):
        if not error and request.results():
            for obs in request.results():
                candidate = obs.topCandidates_(1).firstObject()
                if candidate: extracted_text_lines.append(candidate.string())

    request = Vision.VNRecognizeTextRequest.alloc().initWithCompletionHandler_(completion_handler)
    request.setRecognitionLevel_(0)
    request.setUsesLanguageCorrection_(True)
    handler.performRequests_error_([request], None)
    
    return "\n".join(extracted_text_lines)

# --- 2. THE BRAIN: MedGemma Advanced Pipeline ---
def analyze_advanced_features(raw_text):
    print(f"🧠 [Step 2] Passing extracted text to MedGemma 4B for Advanced Analysis...\n")
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    MODEL_ID = "google/medgemma-4b-it"
    
    tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)
    model = AutoModelForCausalLM.from_pretrained(MODEL_ID, torch_dtype=torch.bfloat16, device_map=device)
    
    # Advanced Prompt Engineering to get structured output
    medical_prompt = f"""<start_of_turn>user
You are an empathetic, highly trained medical assistant.
The following text was extracted from a patient's medical lab report. 

RAW SCANNED TEXT:
{raw_text}

Analyze the clinical data above and provide a report formatted EXACTLY with these 4 headers:

1. PATIENT SUMMARY
(Explain the results logically in very simple, reassuring terms to a patient with no medical background. Do not diagnose.)

2. QUESTIONS FOR YOUR DOCTOR
(Generate 3 highly specific, intelligent questions the patient should ask their doctor at their next visit based on these exact lab results.)

3. TARGETED DIETARY ADVICE
(Provide a brief, 3-step dietary action plan specifically targeted to improve the abnormal metrics found in this report.)

4. MEDICAL GLOSSARY
(Identify the 3 most complex medical terms in the report and provide a simple, 1-sentence definition for each.)
<end_of_turn>
<start_of_turn>model
"""
    
    print("⚙️  MedGemma is analyzing the lab results and generating the advanced report...")
    inputs = tokenizer(medical_prompt, return_tensors="pt").to(device)
    outputs = model.generate(**inputs, max_new_tokens=600, temperature=0.2, do_sample=True)
    
    response = tokenizer.decode(outputs[0], skip_special_tokens=False)
    return response.split("<start_of_turn>model\n")[-1].replace("<end_of_turn>", "").strip()

if __name__ == "__main__":
    image_path = os.path.abspath("sample_record.png")
    
    if not os.path.exists(image_path):
        print("❌ Error: sample_record.png not found in the test_model directory.")
        sys.exit(1)
        
    extracted_text = extract_text(image_path)
    
    if extracted_text:
        final_report = analyze_advanced_features(extracted_text)
        print("\n==================================================")
        print("✨ ADVANCED PATIENT REPORT (From MedGemma):")
        print("==================================================")
        print(final_report)
        print("==================================================\n")
