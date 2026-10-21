import Foundation
import UIKit
import Display
import SwiftSignalKit
import AccountContext
import TelegramCore
import TelegramPresentationData
import TelegramStringFormatting
import ComponentFlow
import AvatarComponent
import BundleIconComponent
import MultilineTextComponent
import PlainButtonComponent
import GiftItemComponent

// MARK: - Model

/// Phase of the "Make an Offer" flow that lives inside the Send Money sheet.
///
/// `.none`        – regular GRAM transfer (existing behaviour).
/// `.pickingGift` – the sheet shows the recipient's offerable collectible gifts.
/// `.gift`        – a gift is chosen; the amount field / keypad are reused to name a price.
enum WalletSendOfferPhase: Equatable {
    case none
    case pickingGift(selected: StarGift.UniqueGift?)
    case gift(StarGift.UniqueGift)

    var isActive: Bool {
        if case .none = self {
            return false
        }
        return true
    }

    var selectedGift: StarGift.UniqueGift? {
        switch self {
        case .none:
            return nil
        case let .pickingGift(selected):
            return selected
        case let .gift(gift):
            return gift
        }
    }
}

/// A gift can receive an offer when it is a collectible owned by the recipient
/// and the owner has not disabled offers (the server sends `offer_min_stars` only
/// for gifts that accept offers – the same check `GiftViewScreen` uses for "Offer to Buy").
func walletSendIsOfferable(_ gift: ProfileGiftsContext.State.StarGift, ownerId: EnginePeer.Id, accountPeerId: EnginePeer.Id) -> StarGift.UniqueGift? {
    guard ownerId != accountPeerId, case let .unique(uniqueGift) = gift.gift else {
        return nil
    }
    guard uniqueGift.minOfferStars != nil else {
        return nil
    }
    if let owner = uniqueGift.owner, case let .peerId(ownerPeerId) = owner, ownerPeerId != ownerId {
        return nil
    }
    return uniqueGift
}

/// How long an offer stays open. Matches "Offer expires in 24 h" in the design;
/// can be overridden from the server with the `stargifts_offer_duration` app config key.
func walletSendGiftOfferDuration(context: AccountContext) -> Int32 {
    if let data = context.currentAppConfiguration.with({ $0 }).data, let value = data["stargifts_offer_duration"] as? Double, value > 0.0 {
        return Int32(value)
    }
    return 24 * 60 * 60
}

/// Loads the recipient's displayed collectible gifts and keeps only the ones that can receive offers.
/// The "Make an Offer" menu item is shown only when this list is non-empty.
final class WalletSendOfferableGiftsLoader {
    struct State: Equatable {
        var gifts: [StarGift.UniqueGift]
        var isLoaded: Bool
    }

    private let profileGifts: ProfileGiftsContext
    private let disposable = MetaDisposable()
    private(set) var state = State(gifts: [], isLoaded: false)
    var updated: ((State) -> Void)?

    init(context: AccountContext, peerId: EnginePeer.Id) {
        self.profileGifts = ProfileGiftsContext(
            account: context.account,
            peerId: peerId,
            sorting: .value,
            filter: [.unique, .displayed]
        )
        let accountPeerId = context.account.peerId
        self.disposable.set((self.profileGifts.state
        |> map { state -> State in
            let gifts = state.filteredGifts.compactMap { walletSendIsOfferable($0, ownerId: peerId, accountPeerId: accountPeerId) }
            var isLoaded = false
            if case .ready = state.dataState {
                isLoaded = true
            }
            return State(gifts: gifts, isLoaded: isLoaded)
        }
        |> distinctUntilChanged
        |> deliverOnMainQueue).start(next: { [weak self] state in
            guard let self else {
                return
            }
            self.state = state
            self.updated?(state)
        }))
    }

    deinit {
        self.disposable.dispose()
    }

    func loadMore() {
        self.profileGifts.loadMore()
    }
}

/// Sends the offer through the existing `payments.sendStarGiftOffer` method with a GRAM (TON) price,
/// handling paid-message recipients and an insufficient GRAM balance the same way `GiftViewScreen` does.
enum WalletSendGiftOfferResult {
    case sent
    case needsPaidMessageConfirmation(StarsAmount)
    case insufficientBalance(needed: StarsAmount)
    case failed
}

func walletSendCommitGiftOffer(
    context: AccountContext,
    peer: EnginePeer,
    gift: StarGift.UniqueGift,
    amountNanograms: Int64,
    comment: String?,
    allowPaidStars: Int64?
) -> Signal<WalletSendGiftOfferResult, NoError> {
    let price = CurrencyAmount(amount: StarsAmount(value: amountNanograms, nanos: 0), currency: .ton)

    if let tonState = context.tonContext?.currentState, tonState.balance < price.amount {
        return .single(.insufficientBalance(needed: price.amount - tonState.balance))
    }

    return context.engine.data.get(TelegramEngine.EngineData.Item.Peer.SendPaidMessageStars(id: peer.id))
    |> mapToSignal { sendPaidMessageStars -> Signal<WalletSendGiftOfferResult, NoError> in
        if let sendPaidMessageStars, sendPaidMessageStars.value > 0, allowPaidStars == nil {
            return .single(.needsPaidMessageConfirmation(sendPaidMessageStars))
        }
        let sendOffer = Signal<WalletSendGiftOfferResult, NoError> { subscriber in
            return context.engine.payments.sendStarGiftOffer(
                peerId: peer.id,
                slug: gift.slug,
                amount: price,
                duration: walletSendGiftOfferDuration(context: context),
                allowPaidStars: allowPaidStars
            ).start(error: { _ in
                subscriber.putNext(.failed)
                subscriber.putCompletion()
            }, completed: {
                subscriber.putNext(.sent)
                subscriber.putCompletion()
            })
        }
        return sendOffer
        |> mapToSignal { result -> Signal<WalletSendGiftOfferResult, NoError> in
            // `messageActionStarGiftPurchaseOffer` has no text field yet, so the optional
            // comment is delivered as a regular message right after the offer card.
            // (See PROPOSAL.md – a `message` field on the action would let the card show it inline.)
            guard case .sent = result, let comment = comment?.trimmingCharacters(in: .whitespacesAndNewlines), !comment.isEmpty else {
                return .single(result)
            }
            return enqueueMessages(account: context.account, peerId: peer.id, messages: [
                .message(text: comment, attributes: [], inlineStickers: [:], mediaReference: nil, threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
            ])
            |> map { _ -> WalletSendGiftOfferResult in
                return .sent
            }
        }
    }
}

private func giftRibbon(for gift: StarGift.UniqueGift, dateTimeFormat: PresentationDateTimeFormat) -> GiftItemComponent.Ribbon {
    var ribbonColor: GiftItemComponent.Ribbon.Color = .blue
    for attribute in gift.attributes {
        if case let .backdrop(_, _, innerColor, outerColor, _, _, _) = attribute {
            ribbonColor = .custom(outerColor, innerColor)
            break
        }
    }
    return GiftItemComponent.Ribbon(text: "#\(formatCollectibleNumber(gift.number, dateTimeFormat: dateTimeFormat))", font: .monospaced, color: ribbonColor, outline: nil)
}

// MARK: - Gift picker ("GIFTS ON PROFILE" grid)

final class WalletSendGiftPickerComponent: Component {
    let context: AccountContext
    let theme: PresentationTheme
    let strings: PresentationStrings
    let dateTimeFormat: PresentationDateTimeFormat
    let peer: EnginePeer
    let gifts: [StarGift.UniqueGift]
    let isLoading: Bool
    let selectedGiftId: Int64?
    let selectGift: (StarGift.UniqueGift) -> Void
    let loadMore: () -> Void

    init(
        context: AccountContext,
        theme: PresentationTheme,
        strings: PresentationStrings,
        dateTimeFormat: PresentationDateTimeFormat,
        peer: EnginePeer,
        gifts: [StarGift.UniqueGift],
        isLoading: Bool,
        selectedGiftId: Int64?,
        selectGift: @escaping (StarGift.UniqueGift) -> Void,
        loadMore: @escaping () -> Void
    ) {
        self.context = context
        self.theme = theme
        self.strings = strings
        self.dateTimeFormat = dateTimeFormat
        self.peer = peer
        self.gifts = gifts
        self.isLoading = isLoading
        self.selectedGiftId = selectedGiftId
        self.selectGift = selectGift
        self.loadMore = loadMore
    }

    static func ==(lhs: WalletSendGiftPickerComponent, rhs: WalletSendGiftPickerComponent) -> Bool {
        if lhs.context !== rhs.context {
            return false
        }
        if lhs.theme !== rhs.theme {
            return false
        }
        if lhs.strings !== rhs.strings {
            return false
        }
        if lhs.peer != rhs.peer {
            return false
        }
        if lhs.gifts != rhs.gifts {
            return false
        }
        if lhs.isLoading != rhs.isLoading {
            return false
        }
        if lhs.selectedGiftId != rhs.selectedGiftId {
            return false
        }
        return true
    }

    final class View: UIView, UIScrollViewDelegate {
        private let header = ComponentView<Empty>()
        private let counter = ComponentView<Empty>()
        private let hint = ComponentView<Empty>()
        private let footer = ComponentView<Empty>()
        private let scrollView = UIScrollView()
        private var items: [Int64: ComponentView<Empty>] = [:]

        private var component: WalletSendGiftPickerComponent?

        override init(frame: CGRect) {
            super.init(frame: frame)

            self.scrollView.delegate = self
            self.scrollView.showsVerticalScrollIndicator = false
            self.scrollView.alwaysBounceVertical = false
            self.scrollView.contentInsetAdjustmentBehavior = .never
            self.addSubview(self.scrollView)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if scrollView.contentOffset.y + scrollView.bounds.height > scrollView.contentSize.height - 120.0 {
                self.component?.loadMore()
            }
        }

        func update(component: WalletSendGiftPickerComponent, availableSize: CGSize, transition: ComponentTransition) -> CGSize {
            self.component = component

            let sideInset: CGFloat = 16.0
            let headerFont = Font.regular(13.0)

            let headerSize = self.header.update(
                transition: .immediate,
                component: AnyComponent(MultilineTextComponent(
                    text: .plain(NSAttributedString(string: component.strings.Wallet_Send_Offer_GiftsOnProfile, font: headerFont, textColor: component.theme.list.freeTextColor)),
                    maximumNumberOfLines: 1
                )),
                environment: {},
                containerSize: CGSize(width: availableSize.width - sideInset * 4.0, height: 20.0)
            )
            let counterSize = self.counter.update(
                transition: .immediate,
                component: AnyComponent(MultilineTextComponent(
                    text: .plain(NSAttributedString(string: "\(component.gifts.count)", font: headerFont, textColor: component.theme.list.freeTextColor)),
                    maximumNumberOfLines: 1
                )),
                environment: {},
                containerSize: CGSize(width: 80.0, height: 20.0)
            )
            if let headerView = self.header.view {
                if headerView.superview == nil {
                    self.addSubview(headerView)
                }
                headerView.frame = CGRect(origin: CGPoint(x: sideInset * 2.0, y: 0.0), size: headerSize)
            }
            if let counterView = self.counter.view {
                if counterView.superview == nil {
                    self.addSubview(counterView)
                }
                counterView.frame = CGRect(origin: CGPoint(x: availableSize.width - sideInset * 2.0 - counterSize.width, y: 0.0), size: counterSize)
            }

            // Same grid geometry as the profile Gifts tab / SelectCraftGiftScreen.
            let itemSpacing: CGFloat = 10.0
            let itemsInRow = availableSize.width > 480.0 ? 5 : 3
            let itemWidth = floor((availableSize.width - sideInset * 2.0 - itemSpacing * CGFloat(itemsInRow - 1)) / CGFloat(itemsInRow))
            let itemSize = CGSize(width: itemWidth, height: itemWidth)

            let gridOriginY = headerSize.height + 8.0
            let rows = max(1, Int(ceil(Double(component.gifts.count) / Double(itemsInRow))))
            let gridHeight = CGFloat(rows) * itemSize.height + CGFloat(rows - 1) * itemSpacing
            let maxGridHeight = max(itemSize.height, availableSize.height - gridOriginY - 96.0)
            let visibleGridHeight = min(gridHeight, maxGridHeight)

            transition.setFrame(view: self.scrollView, frame: CGRect(x: 0.0, y: gridOriginY, width: availableSize.width, height: visibleGridHeight))
            self.scrollView.contentSize = CGSize(width: availableSize.width, height: gridHeight)

            var validIds = Set<Int64>()
            for (index, gift) in component.gifts.enumerated() {
                validIds.insert(gift.id)
                let row = index / itemsInRow
                let column = index % itemsInRow
                let itemFrame = CGRect(
                    x: sideInset + CGFloat(column) * (itemSize.width + itemSpacing),
                    y: CGFloat(row) * (itemSize.height + itemSpacing),
                    width: itemSize.width,
                    height: itemSize.height
                )

                var itemTransition = transition
                let item: ComponentView<Empty>
                if let current = self.items[gift.id] {
                    item = current
                } else {
                    item = ComponentView()
                    self.items[gift.id] = item
                    itemTransition = .immediate
                }
                let _ = item.update(
                    transition: itemTransition,
                    component: AnyComponent(GiftItemComponent(
                        context: component.context,
                        style: .glass,
                        theme: component.theme,
                        strings: component.strings,
                        peer: nil,
                        subject: .uniqueGift(gift: gift, price: nil),
                        ribbon: giftRibbon(for: gift, dateTimeFormat: component.dateTimeFormat),
                        isSelected: component.selectedGiftId == gift.id,
                        mode: .grid,
                        action: { [weak self] in
                            guard let self, let component = self.component else {
                                return
                            }
                            HapticFeedback().impact(.light)
                            component.selectGift(gift)
                        }
                    )),
                    environment: {},
                    containerSize: itemSize
                )
                if let itemView = item.view {
                    if itemView.superview == nil {
                        self.scrollView.addSubview(itemView)
                        if !transition.animation.isImmediate {
                            itemView.layer.animateScale(from: 0.85, to: 1.0, duration: 0.3)
                            itemView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
                        }
                    }
                    itemTransition.setFrame(view: itemView, frame: itemFrame)
                }
            }
            for (id, item) in self.items where !validIds.contains(id) {
                item.view?.removeFromSuperview()
                self.items.removeValue(forKey: id)
            }

            let textFont = Font.regular(15.0)
            let hintSize = self.hint.update(
                transition: .immediate,
                component: AnyComponent(MultilineTextComponent(
                    text: .plain(NSAttributedString(string: component.strings.Wallet_Send_Offer_PickHint, font: textFont, textColor: component.theme.list.itemSecondaryTextColor)),
                    horizontalAlignment: .center,
                    maximumNumberOfLines: 2
                )),
                environment: {},
                containerSize: CGSize(width: availableSize.width - sideInset * 4.0, height: 60.0)
            )
            let hintFrame = CGRect(x: floorToScreenPixels((availableSize.width - hintSize.width) / 2.0), y: gridOriginY + visibleGridHeight + 28.0, width: hintSize.width, height: hintSize.height)
            if let hintView = self.hint.view {
                if hintView.superview == nil {
                    self.addSubview(hintView)
                }
                transition.setFrame(view: hintView, frame: hintFrame)
            }

            let peerName = component.peer.compactDisplayTitle
            let footerSize = self.footer.update(
                transition: .immediate,
                component: AnyComponent(MultilineTextComponent(
                    text: .plain(NSAttributedString(string: component.strings.Wallet_Send_Offer_OnlyVisibleGifts(peerName).string, font: Font.regular(13.0), textColor: component.theme.list.freeTextColor)),
                    horizontalAlignment: .center,
                    maximumNumberOfLines: 2
                )),
                environment: {},
                containerSize: CGSize(width: availableSize.width - sideInset * 4.0, height: 60.0)
            )
            let footerFrame = CGRect(x: floorToScreenPixels((availableSize.width - footerSize.width) / 2.0), y: hintFrame.maxY + 10.0, width: footerSize.width, height: footerSize.height)
            if let footerView = self.footer.view {
                if footerView.superview == nil {
                    self.addSubview(footerView)
                }
                transition.setFrame(view: footerView, frame: footerFrame)
            }

            return CGSize(width: availableSize.width, height: footerFrame.maxY)
        }
    }

    func makeView() -> View {
        return View(frame: .zero)
    }

    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, transition: transition)
    }
}

// MARK: - Gift header ("Timeless Book #59,153 · Owned by …")

/// Replaces the recipient card once a gift has been chosen. Same pill geometry as `WalletSendRecipientComponent`.
final class WalletSendGiftHeaderComponent: Component {
    let context: AccountContext
    let theme: PresentationTheme
    let strings: PresentationStrings
    let dateTimeFormat: PresentationDateTimeFormat
    let peer: EnginePeer
    let gift: StarGift.UniqueGift
    let openGift: () -> Void

    init(
        context: AccountContext,
        theme: PresentationTheme,
        strings: PresentationStrings,
        dateTimeFormat: PresentationDateTimeFormat,
        peer: EnginePeer,
        gift: StarGift.UniqueGift,
        openGift: @escaping () -> Void
    ) {
        self.context = context
        self.theme = theme
        self.strings = strings
        self.dateTimeFormat = dateTimeFormat
        self.peer = peer
        self.gift = gift
        self.openGift = openGift
    }

    static func ==(lhs: WalletSendGiftHeaderComponent, rhs: WalletSendGiftHeaderComponent) -> Bool {
        if lhs.context !== rhs.context {
            return false
        }
        if lhs.theme !== rhs.theme {
            return false
        }
        if lhs.peer != rhs.peer {
            return false
        }
        if lhs.gift != rhs.gift {
            return false
        }
        return true
    }

    final class View: UIView {
        private let backgroundView = UIView()
        private let icon = ComponentView<Empty>()
        private let title = ComponentView<Empty>()
        private let number = ComponentView<Empty>()
        private let ownedBy = ComponentView<Empty>()
        private let avatar = ComponentView<Empty>()
        private let ownerName = ComponentView<Empty>()
        private let infoButton = ComponentView<Empty>()

        override init(frame: CGRect) {
            super.init(frame: frame)
            self.addSubview(self.backgroundView)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(component: WalletSendGiftHeaderComponent, availableSize: CGSize, transition: ComponentTransition) -> CGSize {
            let size = CGSize(width: availableSize.width, height: 63.0)
            self.backgroundView.backgroundColor = component.theme.list.itemInputField.backgroundColor
            self.backgroundView.layer.cornerRadius = size.height / 2.0
            transition.setFrame(view: self.backgroundView, frame: CGRect(origin: .zero, size: size))

            let iconSize = CGSize(width: 40.0, height: 40.0)
            let _ = self.icon.update(
                transition: transition,
                component: AnyComponent(GiftItemComponent(
                    context: component.context,
                    theme: component.theme,
                    strings: component.strings,
                    peer: nil,
                    subject: .uniqueGift(gift: component.gift, price: nil),
                    mode: .tableIcon
                )),
                environment: {},
                containerSize: iconSize
            )
            if let iconView = self.icon.view {
                if iconView.superview == nil {
                    self.addSubview(iconView)
                }
                transition.setFrame(view: iconView, frame: CGRect(origin: CGPoint(x: 14.0, y: floorToScreenPixels((size.height - iconSize.height) / 2.0)), size: iconSize))
            }

            let textOriginX: CGFloat = 64.0
            let textWidth = size.width - textOriginX - 52.0

            let titleSize = self.title.update(
                transition: .immediate,
                component: AnyComponent(MultilineTextComponent(
                    text: .plain(NSAttributedString(string: component.gift.title, font: Font.semibold(16.0), textColor: component.theme.list.itemPrimaryTextColor)),
                    maximumNumberOfLines: 1
                )),
                environment: {},
                containerSize: CGSize(width: textWidth * 0.7, height: 22.0)
            )
            let numberSize = self.number.update(
                transition: .immediate,
                component: AnyComponent(MultilineTextComponent(
                    text: .plain(NSAttributedString(string: "#\(formatCollectibleNumber(component.gift.number, dateTimeFormat: component.dateTimeFormat))", font: Font.regular(16.0), textColor: component.theme.list.itemSecondaryTextColor)),
                    maximumNumberOfLines: 1
                )),
                environment: {},
                containerSize: CGSize(width: textWidth - titleSize.width - 6.0, height: 22.0)
            )
            let line1Y: CGFloat = 11.0
            if let view = self.title.view {
                if view.superview == nil {
                    self.addSubview(view)
                }
                transition.setFrame(view: view, frame: CGRect(origin: CGPoint(x: textOriginX, y: line1Y), size: titleSize))
            }
            if let view = self.number.view {
                if view.superview == nil {
                    self.addSubview(view)
                }
                transition.setFrame(view: view, frame: CGRect(origin: CGPoint(x: textOriginX + titleSize.width + 6.0, y: line1Y), size: numberSize))
            }

            let secondaryFont = Font.regular(14.0)
            let ownedBySize = self.ownedBy.update(
                transition: .immediate,
                component: AnyComponent(MultilineTextComponent(
                    text: .plain(NSAttributedString(string: component.strings.Wallet_Send_Offer_OwnedBy, font: secondaryFont, textColor: component.theme.list.itemSecondaryTextColor)),
                    maximumNumberOfLines: 1
                )),
                environment: {},
                containerSize: CGSize(width: textWidth, height: 20.0)
            )
            let avatarSize = CGSize(width: 18.0, height: 18.0)
            let _ = self.avatar.update(
                transition: .immediate,
                component: AnyComponent(AvatarComponent(context: component.context, theme: component.theme, peer: component.peer, size: avatarSize)),
                environment: {},
                containerSize: avatarSize
            )
            var ownerString = component.peer.compactDisplayTitle
            if let addressName = component.peer.addressName, !addressName.isEmpty {
                ownerString += " @\(addressName)"
            }
            let ownerNameSize = self.ownerName.update(
                transition: .immediate,
                component: AnyComponent(MultilineTextComponent(
                    text: .plain(NSAttributedString(string: ownerString, font: secondaryFont, textColor: component.theme.list.itemSecondaryTextColor)),
                    maximumNumberOfLines: 1
                )),
                environment: {},
                containerSize: CGSize(width: textWidth - ownedBySize.width - avatarSize.width - 10.0, height: 20.0)
            )
            let line2Y = line1Y + titleSize.height + 2.0
            if let view = self.ownedBy.view {
                if view.superview == nil {
                    self.addSubview(view)
                }
                transition.setFrame(view: view, frame: CGRect(origin: CGPoint(x: textOriginX, y: line2Y), size: ownedBySize))
            }
            if let view = self.avatar.view {
                if view.superview == nil {
                    self.addSubview(view)
                }
                transition.setFrame(view: view, frame: CGRect(origin: CGPoint(x: textOriginX + ownedBySize.width + 5.0, y: line2Y + floorToScreenPixels((ownedBySize.height - avatarSize.height) / 2.0)), size: avatarSize))
            }
            if let view = self.ownerName.view {
                if view.superview == nil {
                    self.addSubview(view)
                }
                transition.setFrame(view: view, frame: CGRect(origin: CGPoint(x: textOriginX + ownedBySize.width + avatarSize.width + 10.0, y: line2Y), size: ownerNameSize))
            }

            let infoButtonSize = self.infoButton.update(
                transition: .immediate,
                component: AnyComponent(PlainButtonComponent(
                    content: AnyComponent(BundleIconComponent(
                        name: "Wallet/CardInfo",
                        tintColor: component.theme.list.itemAccentColor,
                        maxSize: CGSize(width: 24.0, height: 24.0)
                    )),
                    minSize: CGSize(width: 44.0, height: 44.0),
                    action: component.openGift
                )),
                environment: {},
                containerSize: CGSize(width: 44.0, height: 44.0)
            )
            if let view = self.infoButton.view {
                if view.superview == nil {
                    self.addSubview(view)
                }
                transition.setFrame(view: view, frame: CGRect(origin: CGPoint(x: size.width - 6.0 - infoButtonSize.width, y: floorToScreenPixels((size.height - infoButtonSize.height) / 2.0)), size: infoButtonSize))
            }

            return size
        }
    }

    func makeView() -> View {
        return View(frame: .zero)
    }

    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, transition: transition)
    }
}
