# Make an Offer — Telegram-iOS implementation

Lets you offer GRAM for a collectible gift straight from the **Send Money to** sheet,
so you don't have to open the gift first.

Written against `TelegramMessenger/Telegram-iOS` (`master`, October 2026) in the codebase's own stack:
ComponentFlow, AsyncDisplayKit, SwiftSignalKit and TelegramCore, with Bazel `swift_library` targets
(`-warnings-as-errors`) and generated `PresentationStrings`.

> **Not compiled.** Building Telegram-iOS needs macOS, Xcode and the Bazel toolchain, and none of
> these were available here. Every API, initializer, asset name and string key used was checked against
> the real source, but treat this as a review-ready patch, not a verified build.

---

## Flow

1. **Send Money to 귀여워** → tap **⋯**.
   - The menu shows **Make an Offer** with a `NEW` badge.
   - The item only appears when the recipient has at least one collectible on their profile that
     accepts offers (`UniqueGift.minOfferStars != nil`, the same check GiftViewScreen uses for
     "Offer to Buy").
   - It never appears when sending to yourself or to a raw address.
2. **Pick a gift.**
   - The sheet becomes **Make an Offer**, and the close button turns into a back button.
   - A **GIFTS ON PROFILE** grid (`GiftItemComponent`, `.glass`, with the backdrop-coloured `#number`
     ribbon) slides in under the recipient card.
   - Nothing is preselected. The button reads **Select a Gift** and stays disabled until a gift is tapped,
     then changes to **Offer on Timeless Book**.
3. **Name a price.**
   - The gift pill (*Timeless Book #59,153 · Owned by 귀여워 @imogen*) takes the recipient card's place.
   - The existing animated amount field and keypad are reused unchanged.
   - Balance and insufficiency switch to the Telegram GRAM balance (`context.tonContext`), and fees are hidden.
   - An escrow note reads: *Offer expires in 24 h · GRAM is held until 귀여워 replies*.
   - The button reads **Offer 120 GRAM**.
4. **Send.**
   - The offer goes through `context.engine.payments.sendStarGiftOffer(…, amount: CurrencyAmount(…, currency: .ton))`.
     This server method already exists; it is what "Offer to Buy" uses today.
   - If the recipient charges stars for messages, `chatMessagePaymentAlertController` asks for
     confirmation, then the offer is retried with `allowPaidStars`.
   - If the balance is short, `BalanceNeededScreen` opens with the Fragment top-up link.
   - On failure, the amount field shakes and an alert appears.
   - Any comment from **⋯ → Add comment** is sent as a follow-up message (see the API gap below).
5. **In chat.**
   - The existing `starGiftPurchaseOffer` service bubble already shows the GRAM price, the countdown
     and Accept / Decline.
   - It now also puts a status ribbon on the gift thumbnail: **offer**, **sold**, **declined** or **expired**.

Back steps through the flow: amount → grid → normal send.

## Files

| File | Change |
|---|---|
| `submodules/TelegramUI/Components/Wallet/WalletSendScreen/Sources/WalletSendGiftOffer.swift` | **New.** `WalletSendOfferPhase`, the offerable-gift filter, `WalletSendOfferableGiftsLoader` (wraps `ProfileGiftsContext`, `[.unique, .displayed]`, sorted by value), `walletSendCommitGiftOffer` (balance check, paid-message check, `sendStarGiftOffer`, comment), `WalletSendGiftPickerComponent`, `WalletSendGiftHeaderComponent`. |
| `…/WalletSendScreen/Sources/WalletSendScreen.swift` | Menu item, the offer phase in `update()`: back/close, title, gift header in place of the recipient, grid, keypad hidden while picking, GRAM balance, escrow note, button title, enabled state and routing. Also `submitOffer` with all result paths. |
| `…/WalletSendScreen/BUILD` | Adds deps on `GiftItemComponent`, `BalanceNeededScreen` and `ChatMessagePaymentAlertController`. No cycles. |
| `…/Chat/ChatMessageGiftOfferBubbleContentNode/Sources/ChatMessageGiftOfferBubbleContentNode.swift` | Status ribbon on the offer card's gift thumbnail. |
| `Telegram/Telegram-iOS/en.lproj/Localizable.strings` | 16 new keys (`Wallet.Send.MakeOffer*`, `Wallet.Send.Offer.*`, `Notification.StarGiftOffer.Ribbon.*`). |

## API gaps (needs a server / TL change)

1. **No comment on offers.**
   - `payments.sendStarGiftOffer` and `messageActionStarGiftPurchaseOffer` have no text field.
   - This patch sends the comment as a normal message right after the offer.
   - Proposal: an optional `message:flags.N?TextWithEntities` on both, so the card can show it inline,
     as `starGift` already does.
2. **Escrow source.**
   - Offers are escrowed from the user's Telegram GRAM balance (`tonContext`), not from the
     self-custody wallet that the Send sheet transfers from.
   - The sheet shows the correct balance and offers a top-up.
   - Paying escrow straight from the linked wallet would need a server-side escrow address and a
     transfer-then-confirm step.
3. **Offer duration.**
   - Read from the app-config key `stargifts_offer_duration`, defaulting to 24 h.
   - The escrow-note string currently says "24 h"; it should become a formatted duration if the server varies it.

## Testing checklist

- [ ] Recipient with no collectibles, or none that accept offers → no menu item.
- [ ] Button reads "Select a Gift" (disabled) until a tile is tapped, then "Offer on Timeless Book".
- [ ] Grid paginates (`loadMore` near the bottom) for profiles with many gifts.
- [ ] Back from amount → grid with the same gift selected; back again → normal send, with the keypad and amount restored.
- [ ] Amount above the GRAM balance → red insufficiency state; Send → `BalanceNeededScreen`.
- [ ] Recipient with paid messages → star confirmation → offer sent.
- [ ] Offer with a comment → offer card, then the comment message.
- [ ] Recipient Accepts → the card ribbon shows **sold**; Decline → **declined**; timeout → **expired**.
- [ ] Changing the recipient mid-flow resets the offer state.
- [ ] Landscape, iPad split view, Dynamic Type XL, RTL, dark theme.
