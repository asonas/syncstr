#!/usr/bin/env python3
"""Collect weekly Simulator results and report persistent failures to Linear."""

import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import urllib.request


TITLE = "Weekly Simulator verification failed"
PROJECT = "7596bdcc-8697-44a6-973a-d04f4ed7e9cc"
TEAM = "5b63ab0c-c50e-4d8a-b895-1ddc27fe09b4"


def test_results(tree):
    """Return final failures and recovered retries from xcresulttool's test tree."""
    failed, flaky = set(), set()

    def repetitions(node):
        if node.get("nodeType") == "Repetition":
            return {node.get("result")}
        return set().union(*(repetitions(child) for child in node.get("children", [])))

    def record(name, node, fallback=None):
        if node.get("result", fallback) == "Failed":
            failed.add(name)
        if {"Passed", "Failed"} <= repetitions(node):
            flaky.add(name)

    def visit(node):
        if isinstance(node, list):
            for item in node:
                visit(item)
        elif isinstance(node, dict):
            if node.get("nodeType") == "Test Case":
                name = node.get("nodeIdentifier") or node["name"]
                arguments = [child for child in node.get("children", [])
                             if child.get("nodeType") == "Arguments"]
                if arguments:
                    for argument in arguments:
                        record(f"{name} [{argument['name']}]", argument, node.get("result"))
                else:
                    record(name, node)
            for value in node.values():
                if isinstance(value, (list, dict)):
                    visit(value)

    visit(tree)
    return sorted(failed), sorted(flaky)


def collect(device, outcome, root):
    failed, flaky, errors = set(), set(), []
    for bundle in sorted(root.glob("**/*.xcresult")):
        try:
            raw = subprocess.check_output([
                "xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle)
            ], text=True, stderr=subprocess.PIPE, timeout=60)
            (bundle.parent / (bundle.stem + "-tests.json")).write_text(raw)
            failures, recovered = test_results(json.loads(raw))
            failed.update(failures)
            flaky.update(recovered)
        except (subprocess.SubprocessError, ValueError) as error:
            errors.append(f"Could not read {bundle.name}: {type(error).__name__}")
    # Earlier preparation attempts remain diagnostic artifacts, not final failures.
    if outcome != "success" and not failed:
        errors.append("Verification failed before test results were available; inspect job logs and artifacts.")
    report = {"device": device, "outcome": outcome, "failed": sorted(failed),
              "flaky": sorted(flaky), "errors": errors}
    root.mkdir(parents=True, exist_ok=True)
    (root / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
        summary.write(render([report]))
    if errors and outcome == "success":
        raise RuntimeError("Could not collect complete Simulator results")


def render(reports):
    lines = ["## Weekly Simulator verification", ""]
    for report in reports:
        lines += [f"### {report['device']}: {report['outcome']}", ""]
        lines += [f"- Failed: `{name}`" for name in report["failed"]]
        lines += [f"- Flaky (passed on retry): `{name}`" for name in report["flaky"]]
        lines += [f"- {error}" for error in report["errors"]]
        if not report["failed"] and not report["flaky"] and not report["errors"]:
            lines.append("No failures or flaky tests.")
        lines.append("")
    return "\n".join(lines)


def request_json(url, payload, headers):
    request = urllib.request.Request(url, data=payload, headers=headers, method="POST")
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def notify(root, job_result):
    reports = [json.loads(path.read_text()) for path in sorted(root.glob("**/report.json"))]
    for device in ("iphone", "ipad"):
        if not any(report["device"] == device for report in reports):
            reports.append({"device": device, "outcome": "failure", "failed": [], "flaky": [],
                            "errors": ["Job did not upload its report; inspect workflow logs."]})
    body = f"Simulator jobs: {job_result}\n\n" + render(reports)
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
        summary.write(body)
    if job_result == "success" and all(report["outcome"] == "success" for report in reports):
        return
    run_url = (f"{os.environ['GITHUB_SERVER_URL']}/{os.environ['GITHUB_REPOSITORY']}"
               f"/actions/runs/{os.environ['GITHUB_RUN_ID']}")
    body = f"Run: {run_url}\n\n{body}"
    credentials = base64.b64encode(
        f"{os.environ['LINEAR_CLIENT_ID']}:{os.environ['LINEAR_CLIENT_SECRET']}".encode()).decode()
    token = request_json("https://api.linear.app/oauth/token",
                         b"grant_type=client_credentials&scope=read%2Cissues%3Acreate%2Ccomments%3Acreate",
                         {"Authorization": "Basic " + credentials,
                          "Content-Type": "application/x-www-form-urlencoded"})["access_token"]
    print("::add-mask::" + token, flush=True)

    def graphql(query, variables):
        result = request_json("https://api.linear.app/graphql",
                              json.dumps({"query": query, "variables": variables}).encode(),
                              {"Authorization": "Bearer " + token, "Content-Type": "application/json"})
        if result.get("errors"):
            # API error bodies may contain sensitive request context.
            raise RuntimeError("Linear GraphQL request failed")
        return result["data"]

    existing = graphql("""query($project: ID!, $title: String!) {
      issues(first: 1, filter: {project: {id: {eq: $project}}, title: {eq: $title},
        state: {type: {nin: ["completed", "canceled"]}}}) {nodes {id identifier url}}
    }""", {"project": PROJECT, "title": TITLE})["issues"]["nodes"]
    if existing:
        result = graphql("""mutation($input: CommentCreateInput!) {
          commentCreate(input: $input) {success}
        }""", {"input": {"issueId": existing[0]["id"], "body": body}})["commentCreate"]
        issue = existing[0]
    else:
        labels = graphql("""query($team: ID!) {
          issueLabels(filter: {name: {eq: "needs-triage"},
            or: [{team: {id: {eq: $team}}}, {team: {null: true}}]}) {nodes {id}}
        }""", {"team": TEAM})["issueLabels"]["nodes"]
        if len(labels) != 1:
            raise RuntimeError("Expected exactly one needs-triage label")
        result = graphql("""mutation($input: IssueCreateInput!) {
          issueCreate(input: $input) {success issue {identifier url}}
        }""", {"input": {"teamId": TEAM, "projectId": PROJECT, "title": TITLE,
                           "description": body, "labelIds": [labels[0]["id"]]}})["issueCreate"]
        issue = result.get("issue", {})
    if not result["success"]:
        raise RuntimeError("Linear did not accept the report")
    print(f"Reported to {issue['identifier']}: {issue['url']}")
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
        summary.write(f"\nLinear: [{issue['identifier']}]({issue['url']})\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("collect", "notify"))
    parser.add_argument("--root", type=Path, default=Path(".build/verification"))
    parser.add_argument("--device", choices=("iphone", "ipad"))
    parser.add_argument("--outcome", required=True)
    args = parser.parse_args()
    if args.action == "collect":
        collect(args.device, args.outcome, args.root)
    else:
        notify(args.root, args.outcome)
