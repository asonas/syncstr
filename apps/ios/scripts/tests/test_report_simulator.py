import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "report_simulator", Path(__file__).resolve().parents[1] / "report_simulator.py")
reporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reporter)


class SimulatorReportTests(unittest.TestCase):
    def test_recovered_repetitions_and_persistent_failures_are_distinct(self):
        tree = {"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": "Suite/recovered()",
            "result": "Passed", "children": [{"nodeType": "Test Case Run", "children": [
                {"nodeType": "Repetition", "result": "Failed"},
                {"nodeType": "Repetition", "result": "Passed"}]}]},
            {"nodeType": "Test Case", "nodeIdentifier": "Suite/broken()", "result": "Failed"},
            {"nodeType": "Test Case", "nodeIdentifier": "Suite/clean()", "result": "Passed"}]}
        self.assertEqual(reporter.test_results(tree), (["Suite/broken()"], ["Suite/recovered()"]))

    def test_different_parameter_results_do_not_count_as_a_retry(self):
        tree = {"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": "Suite/parameterized()",
            "result": "Failed", "children": [
                {"nodeType": "Arguments", "name": "one", "result": "Failed", "children": [
                    {"nodeType": "Repetition", "result": "Failed"}]},
                {"nodeType": "Arguments", "name": "two", "result": "Passed", "children": [
                    {"nodeType": "Repetition", "result": "Passed"}]}]}]}
        self.assertEqual(reporter.test_results(tree), (["Suite/parameterized() [one]"], []))

    def notify(self, existing):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for device in ("iphone", "ipad"):
                (root / device).mkdir()
                (root / device / "report.json").write_text(json.dumps({
                    "device": device, "outcome": "failure", "failed": ["Suite/broken()"],
                    "flaky": ["Suite/recovered()"], "errors": []}))
            environment = {"GITHUB_STEP_SUMMARY": str(root / "summary.md"),
                "GITHUB_SERVER_URL": "https://github.com", "GITHUB_REPOSITORY": "example/music",
                "GITHUB_RUN_ID": "123", "LINEAR_CLIENT_ID": "fictional-client",
                "LINEAR_CLIENT_SECRET": "fictional-secret"}
            responses = [{"access_token": "fictional-token"},
                         {"data": {"issues": {"nodes": existing}}}]
            if existing:
                responses.append({"data": {"commentCreate": {"success": True}}})
            else:
                responses += [{"data": {"issueLabels": {"nodes": [{"id": "triage-label"}]}}},
                    {"data": {"issueCreate": {"success": True,
                        "issue": {"identifier": "TEST-1", "url": "https://example.com/issue"}}}}]
            output = io.StringIO()
            with patch.dict(os.environ, environment), \
                    patch.object(reporter, "request_json", side_effect=responses) as request, \
                    contextlib.redirect_stdout(output):
                reporter.notify(root, "failure")
            calls = request.call_args_list
            self.assertEqual(calls[0].args[1],
                b"grant_type=client_credentials&scope=read%2Cissues%3Acreate%2Ccomments%3Acreate")
            self.assertTrue(output.getvalue().startswith("::add-mask::fictional-token\n"))
            self.assertNotIn("fictional-secret", output.getvalue())
            mutation = json.loads(calls[-1].args[1])
            body = mutation["variables"]["input"].get("body") or mutation["variables"]["input"]["description"]
            for text in ("iphone", "ipad", "Suite/broken()", "Suite/recovered()", "/actions/runs/123"):
                self.assertIn(text, body)
            return mutation

    def test_first_failure_creates_labeled_project_issue(self):
        mutation = self.notify([])
        values = mutation["variables"]["input"]
        self.assertEqual(values["projectId"], reporter.PROJECT)
        self.assertEqual(values["teamId"], reporter.TEAM)
        self.assertEqual(values["labelIds"], ["triage-label"])

    def test_repeat_failure_comments_instead_of_creating(self):
        mutation = self.notify([{"id": "existing", "identifier": "TEST-1", "url": "https://example.com/issue"}])
        self.assertEqual(mutation["variables"]["input"]["issueId"], "existing")
        self.assertIn("commentCreate", mutation["query"])

    def test_success_never_authenticates(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for device in ("iphone", "ipad"):
                (root / device).mkdir()
                (root / device / "report.json").write_text(json.dumps({
                    "device": device, "outcome": "success", "failed": [], "flaky": [], "errors": []}))
            with patch.dict(os.environ, GITHUB_STEP_SUMMARY=str(root / "summary.md")), \
                    patch.object(reporter, "request_json") as request:
                reporter.notify(root, "success")
            request.assert_not_called()


if __name__ == "__main__":
    unittest.main()
