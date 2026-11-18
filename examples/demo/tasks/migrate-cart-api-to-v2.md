---
id: migrate-cart-api-to-v2
title: Migrate cart API calls to v2
status: working
parent: revamp-checkout-flow
jira: SHOP-431
pr: https://github.com/example/shop/pull/231
cursor_agent: 617e7b4c-1c4b-4cf2-8a98-d881f2dc99b5
workspace: ~/code/shop
branch: cart-api-v2
created: 2026-11-17T14:00:00Z
updated: 2026-11-18T16:40:00Z
---

Swap every `/v1/cart` call for the v2 client. Keep the old client behind the `legacy_cart` flag until the rollout finishes.
