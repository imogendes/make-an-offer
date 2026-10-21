# Make an Offer

Offer GRAM for someone's Telegram gift straight from the Gram wallet's Send Money sheet.

https://github.com/imogendes/make-an-offer/raw/main/demo.mp4

## How it works

1. In any chat, open the attachment menu and tap **Money** to open **Send Money**.
2. Tap **⋯** and choose **Make an Offer** (shown only when the recipient has gifts that accept offers).
3. Pick one of the gifts on their profile, then enter your price in GRAM on the usual keypad. You can add an optional comment.
4. Tap **Offer N Grams**. The GRAM is held in escrow until the owner replies, and the offer expires after 24 hours.
5. The owner gets an offer card in chat and taps it to see the details, then **Accept** or **Decline**.
6. A status ribbon on the card shows the state: **offer**, **sold**, **declined** or **expired**. On accept, both sides see a system message confirming the sale.

## Why

- It turns browsing into buying in seconds, inside a flow people already use.
- It brings more GRAM volume into the gift market.
- It's cheap to ship: it uses the existing gift offer server method, which already supports GRAM, and reuses native components.

## Contents

- `demo.mp4`: the animated demo of the full flow
- `make-an-offer.patch`: the implementation patch for [Telegram-iOS](https://github.com/TelegramMessenger/Telegram-iOS)
- `submodules/` and `Telegram/`: the changed source files from the patch, for easy reading
- [IMPLEMENTATION.md](IMPLEMENTATION.md): how the patch works, how to test it, and two small API suggestions

To try it, apply the patch to a Telegram-iOS checkout with `git apply make-an-offer.patch`. It was written against the current source but hasn't been built locally yet.

Suggested by [@imogen](https://t.me/imogen)
