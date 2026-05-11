#!/bin/bash

echo "🚀 Setting up the Python environment to test MedGemma..."

# Go to the test_model directory
cd /Users/bilalshihab/dev/med_llm/test_model

# Create a virtual environment
python3 -m venv venv

# Activate it
source venv/bin/activate

echo "📦 Installing llama-cpp-python with Apple Metal (GPU) support..."
# This flag ensures that the C++ code compiles to use your Mac's M-series GPU for massive speed
CMAKE_ARGS="-DGGML_METAL=on" pip install --force-reinstall llama-cpp-python huggingface_hub

echo ""
echo "✅ Setup complete! To run the test, copy and paste this command into your terminal:"
echo ""
echo "cd /Users/bilalshihab/dev/med_llm/test_model && source venv/bin/activate && python test_medgemma.py"
echo ""
