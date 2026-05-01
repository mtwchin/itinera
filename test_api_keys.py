#!/usr/bin/env python3
"""
API Key Tester - Verify your API keys are working correctly
Run this before starting the main app to ensure everything is configured properly.
"""

import os
from dotenv import load_dotenv
import sys

# Load environment variables
load_dotenv()


def test_openai():
    """Test OpenAI API key"""
    print("\n🤖 Testing OpenAI API...")
    try:
        from openai import OpenAI

        api_key = os.getenv("OPENAI_API_KEY")

        if not api_key or api_key == "your_openai_api_key_here":
            print("❌ OpenAI API key not configured in .env file")
            return False

        client = OpenAI(api_key=api_key)

        # Make a minimal test call
        response = client.chat.completions.create(
            model="gpt-4o-mini",
            messages=[{"role": "user", "content": "Say 'test'"}],
            max_tokens=5,
        )

        print("✅ OpenAI API key is valid!")
        print(f"   Model: {response.model}")
        return True

    except Exception as e:
        print(f"❌ OpenAI API error: {str(e)}")
        return False


def test_google_maps():
    """Test Google Maps API key"""
    print("\n🗺️  Testing Google Maps API...")
    try:
        import googlemaps

        api_key = os.getenv("GOOGLE_MAPS_API_KEY")

        if not api_key or api_key == "your_google_maps_api_key_here":
            print("❌ Google Maps API key not configured in .env file")
            return False

        gmaps = googlemaps.Client(key=api_key)

        # Test geocoding
        result = gmaps.geocode("Tokyo, Japan")

        if result:
            print("✅ Google Maps API key is valid!")
            print(f"   Geocoding test successful")
            return True
        else:
            print("❌ Google Maps API returned no results")
            return False

    except Exception as e:
        print(f"❌ Google Maps API error: {str(e)}")
        return False


def test_tiktok():
    """Test TikTok API key (optional)"""
    print("\n🎬 Testing TikTok API...")
    try:
        import requests

        api_key = os.getenv("TIKTOK_API_KEY")

        if not api_key or api_key == "your_tiktok_api_key_here":
            print(
                "⚠️  TikTok API key not configured (optional - app will use simulation)"
            )
            return None

        # Basic connectivity test
        headers = {
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        }

        # Note: This is a simplified test. Actual endpoint depends on your TikTok API access
        print("⚠️  TikTok API configured but not tested (requires Research API access)")
        print("   App will attempt to use it, or fall back to simulation")
        return None

    except Exception as e:
        print(f"⚠️  TikTok API check failed: {str(e)}")
        print("   App will use simulated data")
        return None


def main():
    """Run all API tests"""
    print("=" * 60)
    print("🔑 Itinera API Key Tester")
    print("=" * 60)

    # Check if .env exists
    if not os.path.exists(".env"):
        print("\n❌ ERROR: .env file not found!")
        print("   Please create a .env file with your API keys")
        print("   You can copy .env.example and fill in your keys")
        sys.exit(1)

    results = {
        "openai": test_openai(),
        "google_maps": test_google_maps(),
        "tiktok": test_tiktok(),
    }

    print("\n" + "=" * 60)
    print("📊 Summary")
    print("=" * 60)

    if results["openai"] and results["google_maps"]:
        print("\n✅ All required API keys are working!")
        print("   You can now run: python app.py")
        return True
    else:
        print("\n❌ Some required API keys are not working")
        print("\nRequired:")
        print(f"  - OpenAI: {'✅' if results['openai'] else '❌'}")
        print(f"  - Google Maps: {'✅' if results['google_maps'] else '❌'}")
        print("\nOptional:")
        print(
            f"  - TikTok: {'✅' if results['tiktok'] else '⚠️ Not configured (will use simulation)'}"
        )
        print("\nPlease fix the issues above before running the app.")
        return False


if __name__ == "__main__":
    try:
        success = main()
        sys.exit(0 if success else 1)
    except KeyboardInterrupt:
        print("\n\n⚠️  Test interrupted by user")
        sys.exit(1)
