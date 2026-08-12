import plistlib
from pathlib import Path


def test_privacy_manifest_discloses_linked_email_for_apple_recovery():
    manifest = plistlib.loads(Path("ios/Itinera/PrivacyInfo.xcprivacy").read_bytes())
    declarations = {
        item["NSPrivacyCollectedDataType"]: item
        for item in manifest["NSPrivacyCollectedDataTypes"]
    }

    email = declarations["NSPrivacyCollectedDataTypeEmailAddress"]
    assert email["NSPrivacyCollectedDataTypeLinked"] is True
    assert email["NSPrivacyCollectedDataTypeTracking"] is False
    assert email["NSPrivacyCollectedDataTypePurposes"] == [
        "NSPrivacyCollectedDataTypePurposeAppFunctionality"
    ]
