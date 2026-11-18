---
id: fix-flaky-payment-webhook-test
title: Fix flaky payment webhook test
status: idle
parent: revamp-checkout-flow
pr: https://github.com/example/shop/pull/228
cursor_agent: 2b9d0c1e-77aa-4f0e-9d53-0a1f6c2e8b11
workspace: ~/code/shop
branch: fix-webhook-test
created: 2026-11-16T11:00:00Z
updated: 2026-11-18T15:10:00Z
---

`test_webhook_retries` fails about one run in five. The retry timer uses the wall clock; inject a fake clock instead.
