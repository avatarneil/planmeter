import copy
import datetime
import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location("signing", pathlib.Path(__file__).resolve().parents[2] / "scripts/configure-icloud-signing.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class CloudSigningTests(unittest.TestCase):
    def setUp(self):
        self.info = {"CFBundleIdentifier": "com.neilgoldader.planmeter"}
        self.entitlements = {
            "com.apple.application-identifier": "R668T822R7.com.neilgoldader.planmeter",
            "com.apple.security.application-groups": ["R668T822R7.com.neilgoldader.planmeter.desktop"],
        }
        self.profile = {
            "ExpirationDate": datetime.datetime.now() + datetime.timedelta(days=30),
            "Entitlements": {
                **self.entitlements,
                "com.apple.developer.team-identifier": "R668T822R7",
                "com.apple.developer.icloud-services": "*",
                "com.apple.developer.icloud-container-identifiers": ["iCloud.com.neilgoldader.planmeter"],
                "com.apple.developer.icloud-container-environment": ["Production", "Development"],
            },
        }

    def test_preserves_widget_entitlements_and_selects_environment(self):
        for environment in ("Production", "Development"):
            result = signing.validated_entitlements(self.profile, self.info, self.entitlements, environment)
            self.assertEqual(result["com.apple.developer.icloud-container-environment"], environment)
            self.assertEqual(result["com.apple.security.application-groups"], self.entitlements["com.apple.security.application-groups"])
            self.assertEqual(result["com.apple.developer.icloud-services"], ["CloudKit"])

    def test_accepts_single_environment_profile(self):
        self.profile["Entitlements"]["com.apple.developer.icloud-container-environment"] = "Production"
        signing.validated_entitlements(self.profile, self.info, self.entitlements, "Production")
        with self.assertRaises(ValueError):
            signing.validated_entitlements(self.profile, self.info, self.entitlements, "Development")

    def test_rejects_wrong_app_container_service_team_or_expired_profile(self):
        for key, value in {
            "com.apple.application-identifier": "OTHER.com.neilgoldader.planmeter",
            "com.apple.developer.icloud-container-identifiers": [],
            "com.apple.developer.icloud-services": ["CloudDocuments"],
            "com.apple.developer.team-identifier": "OTHER",
        }.items():
            with self.subTest(key=key):
                profile = copy.deepcopy(self.profile)
                profile["Entitlements"][key] = value
                with self.assertRaises(ValueError):
                    signing.validated_entitlements(profile, self.info, self.entitlements, "Production")
        self.profile["ExpirationDate"] = datetime.datetime(2000, 1, 1)
        with self.assertRaises(ValueError):
            signing.validated_entitlements(self.profile, self.info, self.entitlements, "Production")
