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

## Retention message "Keep yPrompt Pro" (submitted Nov 6, 2026)

- **Status:** submitted to App Review on Nov 6, 2026, "Waiting for Review" (Apple says up to 48 hours). Approval date: _pending_
- **What it does:** shown when someone taps Cancel Subscription on Annual or Weekly. Paying subscribers with at least 1 paid month also get the offer below. People cancelling during the free trial see only the text.
- **Setup:** no image. No app update needed.
- **App Store Connect:** Subscriptions → Retention Messaging → Keep yPrompt Pro (`retention-messages/872c818e-9b93-4b33-bae4-a2a8f584ebfe`).
- **Limits:** header 66 characters, body 144. No prices or offers allowed in the text; Apple adds the offer itself.

| Locale | Header | Body |
|---|---|---|
| en-US | Keep every script and Voice Scroll | Pro keeps unlimited scripts, Voice Scroll that follows your words, Lyrics Style, camera recording and the Mac notch teleprompter. |
| fr-FR, fr-CA | Gardez tous vos textes et le Défilement Vocal | Avec Pro : textes illimités, Défilement Vocal qui suit votre voix, Style paroles, enregistrement caméra et prompteur dans l'encoche du Mac. |
| de-DE | Behalte alle Skripte und Voice Scroll | Mit Pro: unbegrenzte Skripte, Voice Scroll, das deinen Worten folgt, Lyrics-Stil, Kameraaufnahme und der Mac-Notch-Teleprompter. |
| es-ES, es-MX | Conserva todos tus guiones y el Desplazamiento por Voz | Con Pro: guiones ilimitados, Desplazamiento por Voz que sigue tu voz, Estilo letras, grabación con cámara y teleprompter en el notch del Mac. |
| it | Tieni tutti i copioni e lo Scorrimento Vocale | Con Pro: copioni illimitati, Scorrimento Vocale che segue la voce, Stile testi, registrazione con fotocamera e teleprompter nel notch del Mac. |
| pt-BR | Mantenha todos os roteiros e a Rolagem por voz | Com o Pro: roteiros ilimitados, Rolagem por voz que segue sua fala, Estilo letra de música, gravação com câmera e teleprompter no notch do Mac. |
| id | Simpan semua naskah dan Gulir Suara | Dengan Pro: naskah tanpa batas, Gulir Suara yang mengikuti ucapanmu, Gaya Lirik, rekaman kamera, dan teleprompter di notch Mac. |

These translations still need a native speaker's review, like the rest of the store copy.

| Field | Annual | Weekly |
|---|---|---|
| Reference name | Retention Annual 50% | Retention Weekly 50% |
| Offer identifier | `retention_annual_50` | `retention_weekly_50` |
| Type | Pay up front, 1 year | Pay as you go, 4 weeks |
| US price | $24.99 (regular $49.99) | $2.99/week (regular $5.99) |
| Paid subscription duration | At least 1 month | At least 1 month |
| Wait between offers | 12 months | 6 months |
| Countries | All 175 | All 175 |

## Billing grace period (turned on Nov 13, 2026)

- **Duration:** 16 days, the same as Poly.
- **Eligible subscribers:** all renewals, so a free trial whose first charge fails is covered too.
- **Environments:** production and sandbox.
- **What it does:** when a renewal payment fails, the subscriber keeps Pro for up to 16 days while Apple retries. If the payment goes through in that time, there is no gap in paid days.
- **In the app:** `StoreKitService.refreshEntitlements()` counts a subscription in its grace period as Pro. Versions up to 1.0.6 also count one in billing retry, which Apple can run for up to 60 days in all. From the next app update, Pro ends when the grace period does.
- **Why:** from Oct 1 to Nov 12, five free trials failed at their first charge and four were paid.
- **App Store Connect:** Subscriptions → Billing Grace Period.
