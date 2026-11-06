# yPrompt — subscription offers

## Win-back offers (created Nov 6, 2026)

Created in App Store Connect only. No app update needed: `StoreKitService` doesn't intercept StoreKit messages, so Apple's win-back sheet shows on its own (iOS 18+). A purchase from it arrives through the existing `Transaction.updates` listener. Eligible former subscribers also see the offer in Manage Subscriptions.

| Field | Annual (`yp_4999_1y`) | Weekly (`yp_599_1w`) |
|---|---|---|
| Apple ID | 6831617235 | 6831617923 |
| Reference name | Win-back Annual 50% | Win-back Weekly 50% |
| Offer identifier | `winback_annual_50` | `winback_weekly_50` |
| Billing plan | 1 Year Upfront | Weekly |
| Dates | Nov 7, 2026 → no end date | Nov 7, 2026 → no end date |
| Priority | Normal | Normal |
| Minimum paid duration | 1 month | 1 month |
| Time since last subscribed | 1–24 months | 1–24 months |
| Wait between offers | 12 months | 6 months |
| Type | Pay up front, 1 year | Pay as you go, 4 weeks |
| US | $24.99 (regular $49.99) | $2.99/week (regular $5.99) |
| Philippines | ₱1,490 (regular ₱2,990) | ₱199/week (regular ₱399) |
| Indonesia | Rp 499,000 (regular Rp 799,000) | Rp 59,000/week (regular Rp 99,000) |
| Malaysia | RM 119.90 (regular RM 229.90) | RM 14.90/week (regular RM 29.90) |
| France | €29.99 (regular €59.99) | €2.99/week (regular €6.99) |
| United Kingdom | £24.99 (regular £49.99) | £2.99/week (regular £5.99) |
| Countries | All 175 | All 175 |
| Promoted on the App Store | No | No |

Promotion stays off: promoting puts the offer on the product page, which counts as a listing change.

Prices can't be changed after creation. If the Philippines, Indonesia or Malaysia subscription prices change, delete the matching offer and create a new one. Monthly (`yp_499_1m`) is removed from sale and has no offer. Neither does the Annual "Monthly with a 12-Month Commitment" plan.

Very few people qualify yet: they need at least 1 paid month, then a lapsed subscription. Read results in Sales and Trends by offer identifier.

## Not set up yet

- **Billing grace period:** off. Without it, a subscriber whose payment fails loses Pro right away. Poly uses 16 days for all renewals.
- **Retention message with an offer** (Subscriptions → Retention Messaging): none yet. Poly has one, "Keep Premium".
