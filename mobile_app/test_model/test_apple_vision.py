import os
import sys

# We use PyObjC to natively access Apple's macOS/iOS Vision Framework
try:
    import Quartz
    import Vision
    from Foundation import NSURL
except ImportError:
    print("❌ Missing Apple Vision bindings. Make sure you installed pyobjc-framework-Vision")
    sys.exit(1)

def extract_text_with_apple_vision(image_path):
    print(f"👁️  Booting up Apple's Native Neural Engine (VisionKit)...")
    print(f"📁 Scanning image: {os.path.basename(image_path)}\n")
    
    if not os.path.exists(image_path):
        print(f"❌ Error: Could not find the file at {image_path}")
        return None

    # Load the image using Apple's Foundation URLs
    input_url = NSURL.fileURLWithPath_(image_path)
    
    # Create the Vision image handler
    handler = Vision.VNImageRequestHandler.alloc().initWithURL_options_(input_url, None)
    
    extracted_text_lines = []
    
    # Define the callback function that runs when Apple finishes scanning
    def completion_handler(request, error):
        if error:
            print(f"❌ VisionKit Error: {error}")
            return
            
        observations = request.results()
        if not observations:
            print("⚠️ VisionKit could not find any text in this image.")
            return
            
        for obs in observations:
            # topCandidates_(1) returns the highest-confidence text prediction
            candidate = obs.topCandidates_(1).firstObject()
            if candidate:
                extracted_text_lines.append(candidate.string())

    # Create the Text Recognition Request (This is the exact API the iPhone uses)
    request = Vision.VNRecognizeTextRequest.alloc().initWithCompletionHandler_(completion_handler)
    
    # Set to 0 for VNRequestTextRecognitionLevelAccurate (Highest quality OCR)
    request.setRecognitionLevel_(0)
    
    # Enable language correction so it uses Apple's dictionary to fix typos
    request.setUsesLanguageCorrection_(True)
    
    # Execute the scan!
    success, error = handler.performRequests_error_([request], None)
    
    if not success:
        print(f"❌ Failed to perform OCR scan: {error}")
        return None
        
    return "\n".join(extracted_text_lines)

if __name__ == "__main__":
    # We will look for a test image in the same folder
    TARGET_IMAGE = "sample_record.png"
    
    # Check if user provided an argument
    if len(sys.argv) > 1:
        TARGET_IMAGE = sys.argv[1]
        
    abs_path = os.path.abspath(TARGET_IMAGE)
    
    if not os.path.exists(abs_path):
        print(f"⚠️  Please place an image file named '{TARGET_IMAGE}' in this folder.")
        print(f"Or run the script with a specific file: python test_apple_vision.py path/to/your/image.png")
    else:
        text = extract_text_with_apple_vision(abs_path)
        
        if text:
            print("--------------------------------------------------")
            print("📄 EXTRACTED TEXT FROM APPLE VISION:")
            print("--------------------------------------------------")
            print(text)
            print("--------------------------------------------------\n")
            print("✅ This is the exact raw text that we will feed into MedGemma!")
