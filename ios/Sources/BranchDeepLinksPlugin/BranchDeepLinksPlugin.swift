import Foundation
import Capacitor
import BranchSDK

typealias JSObject = [String: Any]

@objc(BranchDeepLinks)
public class BranchDeepLinks: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "BranchDeepLinks"
    public let jsName = "BranchDeepLinks"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "generateShortUrl", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "showShareSheet", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getStandardEvents", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "sendBranchEvent", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "handleATTAuthorizationStatus", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "disableTracking", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setIdentity", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "logout", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getBranchQRCode", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getLatestReferringParams", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getFirstReferringParams", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setDMAParamsForEEA", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "handleUrl", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setConsumerProtectionAttributionLevel", returnType: CAPPluginReturnPromise)
    ]

    var branchService = BranchService()

    public override func load() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(branchDidStartSession(notification:)),
            name: NSNotification.Name.BranchDidStartSession,
            object: nil
        )
        Branch.getInstance().registerPluginName("Capacitor", version: "1.0.1")
    }

    @objc public func setBranchService(branchService: Any) {
        self.branchService = branchService as! BranchService
    }

    @objc public func branchDidStartSession(notification: Notification) {
        if let error = notification.userInfo?[BranchErrorKey] as? Error {
            notifyListeners("initError", data: ["error": error.localizedDescription], retainUntilConsumed: true)
        } else {
            let linkprops = notification.userInfo?[BranchLinkPropertiesKey] as? BranchLinkProperties
            let universalobject = notification.userInfo?[BranchUniversalObjectKey] as? BranchUniversalObject
            var referringParams = JSObject()
            for (key, value) in linkprops?.controlParams ?? [:] {
                referringParams[key.base as! String] = value
            }
            for (key, value) in universalobject?.contentMetadata.customMetadata ?? [:] {
                referringParams[key as! String] = value
            }
            notifyListeners("init", data: ["referringParams": referringParams], retainUntilConsumed: true)
        }
    }

    @objc func generateShortUrl(_ call: CAPPluginCall) {
        let analytics = call.getObject("analytics") ?? [:]
        let properties = call.getObject("properties") ?? [:]
        let linkProperties = getLinkProperties(analytics: analytics, properties: properties)
        let params = NSMutableDictionary()
        params.addEntries(from: linkProperties.controlParams)
        branchService.generateShortUrl(params: params as? [AnyHashable: Any] ?? [:], linkProperties: linkProperties) { url, error in
            if error == nil {
                call.resolve(["url": url ?? ""])
            } else {
                call.reject(error?.localizedDescription ?? "Error generating short url")
            }
        }
    }

    @objc func handleATTAuthorizationStatus(_ call: CAPPluginCall) {
        if let value = call.getInt("status") {
            Branch.getInstance().handleATTAuthorizationStatus(UInt(value))
            call.resolve()
            return
        }
        call.reject("No status was provided.")
    }

    @objc func showShareSheet(_ call: CAPPluginCall) {
        let analytics = call.getObject("analytics") ?? [:]
        let properties = call.getObject("properties") ?? [:]
        let shareText = call.getString("shareText", "Share Link")
        let linkProperties = getLinkProperties(analytics: analytics, properties: properties)
        let buo = BranchUniversalObject()
        DispatchQueue.main.async {
            buo.showShareSheet(with: linkProperties, andShareText: shareText, from: self.bridge?.viewController)
        }
        call.resolve()
    }

    @objc func getStandardEvents(_ call: CAPPluginCall) {
        let standardEvents: [BranchStandardEvent] = [
            .achieveLevel, .addPaymentInfo, .addToCart, .addToWishlist,
            .completeRegistration, .completeTutorial, .initiatePurchase,
            .purchase, .rate, .search, .share, .unlockAchievement,
            .viewCart, .viewItem, .viewItems
        ]
        call.resolve(["branch_standard_events": standardEvents])
    }

    @objc func sendBranchEvent(_ call: CAPPluginCall) {
        guard let eventName = call.options["eventName"] as? String else {
            call.reject("Must provide an event name")
            return
        }
        let metaData = call.getObject("metaData") ?? [:]
        let event = BranchEvent.customEvent(withName: eventName)
        for (key, value) in metaData {
            switch key {
            case "transactionID": event.transactionID = value as? String
            case "currency": event.currency = (value as? String).map { BNCCurrency(rawValue: $0) }
            case "shipping": event.shipping = NSDecimalNumber(decimal: (value as? NSNumber ?? 0).decimalValue)
            case "tax": event.tax = NSDecimalNumber(decimal: (value as? NSNumber ?? 0).decimalValue)
            case "coupon": event.coupon = value as? String
            case "affiliation": event.affiliation = value as? String
            case "eventDescription", "description": event.eventDescription = value as? String
            case "revenue": event.revenue = NSDecimalNumber(decimal: (value as? NSNumber ?? 0).decimalValue)
            case "searchQuery": event.searchQuery = value as? String
            case "customerEventAlias": event.alias = value as? String
            case "customData": event.customData = value as? [String: String] ?? [:]
            case "contentMetadata":
                if let items = value as? NSMutableArray {
                    event.contentItems = items.compactMap { ($0 as? [String: Any]).map { getContentItemObject(item: $0) } }
                }
            default: break
            }
        }
        event.logEvent()
        call.resolve()
    }

    @objc func disableTracking(_ call: CAPPluginCall) {
        let isEnabled = call.getBool("isEnabled") ?? false
        branchService.disableTracking(isEnabled: isEnabled) { enabled in
            call.resolve(["is_enabled": enabled])
        }
    }

    @objc func setIdentity(_ call: CAPPluginCall) {
        let newIdentity = call.getString("newIdentity") ?? ""
        branchService.setIdentity(newIdentity: newIdentity) { referringParams, _ in
            call.resolve(["referringParams": referringParams ?? [:]])
        }
    }

    @objc func logout(_ call: CAPPluginCall) {
        branchService.logout { loggedOut, error in
            if error == nil {
                call.resolve(["logged_out": loggedOut as Any])
            } else {
                call.reject(error?.localizedDescription ?? "Error logging out")
            }
        }
    }

    @objc func getBranchQRCode(_ call: CAPPluginCall) {
        let analytics = call.getObject("analytics") ?? [:]
        let properties = call.getObject("properties") ?? [:]
        let linkProperties = getLinkProperties(analytics: analytics, properties: properties)
        let buo = BranchUniversalObject()
        let qrCodeSettingsMap = call.getObject("settings") ?? [:]
        let qrCode = BranchQRCode()
        if let codeColor = qrCodeSettingsMap["codeColor"] as? String { qrCode.codeColor = colorWithHexString(hexString: codeColor) }
        if let backgroundColor = qrCodeSettingsMap["backgroundColor"] as? String { qrCode.backgroundColor = colorWithHexString(hexString: backgroundColor) }
        if let centerLogo = qrCodeSettingsMap["centerLogo"] as? String { qrCode.centerLogo = centerLogo }
        if let margin = qrCodeSettingsMap["margin"] as? NSNumber { qrCode.margin = margin }
        if let width = qrCodeSettingsMap["width"] as? NSNumber { qrCode.width = width }
        if let imageFormat = qrCodeSettingsMap["imageFormat"] as? String {
            qrCode.imageFormat = imageFormat == "JPEG" ? .JPEG : .PNG
        }
        branchService.getBranchQRCode(branchQRCode: qrCode, buo: buo, linkProperties: linkProperties) { qrCodeString, error in
            if error == nil {
                call.resolve(["qrCode": qrCodeString ?? ""])
            } else {
                call.reject(error?.localizedDescription ?? "Error generating QR code")
            }
        }
    }

    @objc func getLatestReferringParams(_ call: CAPPluginCall) {
        branchService.getLatestReferringParams { params in call.resolve(["referringParams": params]) }
    }

    @objc func getFirstReferringParams(_ call: CAPPluginCall) {
        branchService.getFirstReferringParams { params in call.resolve(["referringParams": params]) }
    }

    @objc func setDMAParamsForEEA(_ call: CAPPluginCall) {
        guard let eeaRegion = call.getBool("eeaRegion"),
              let adPersonalizationConsent = call.getBool("adPersonalizationConsent"),
              let adUserDataUsageConsent = call.getBool("adUserDataUsageConsent") else {
            call.reject("One or more DMA parameters are missing")
            return
        }
        branchService.setDMAParamsForEEA(eeaRegion: eeaRegion, adPersonalizationConsent: adPersonalizationConsent, adUserDataUsageConsent: adUserDataUsageConsent)
        call.resolve()
    }

    @objc func handleUrl(_ call: CAPPluginCall) {
        guard let url = call.getString("branch") else {
            call.reject("The object passed must contain a 'branch' key with a string value")
            return
        }
        branchService.handleUrl(url: url) { error in
            if let error = error { call.reject(error.localizedDescription) } else { call.resolve() }
        }
    }

    @objc func setConsumerProtectionAttributionLevel(_ call: CAPPluginCall) {
        guard let level = call.getString("level") else {
            call.reject("Must provide a valid attribution level")
            return
        }
        branchService.setConsumerProtectionAttributionLevel(level: level)
        call.resolve()
    }

    // MARK: - Helpers

    func getLinkProperties(analytics: [String: Any], properties: [String: Any]) -> BranchLinkProperties {
        let lp = BranchLinkProperties()
        for (key, value) in analytics {
            switch key {
            case "alias": lp.alias = value as? String
            case "campaign": lp.campaign = value as? String
            case "channel": lp.channel = value as? String
            case "duration": lp.matchDuration = value as? UInt ?? 0
            case "feature": lp.feature = value as? String
            case "stage": lp.stage = value as? String
            case "tags": lp.tags = value as? [Any]
            default: break
            }
        }
        for (key, value) in properties { lp.addControlParam(key, withValue: value as? String) }
        return lp
    }

    func getContentItemObject(item: [String: Any]) -> BranchUniversalObject {
        let object = BranchUniversalObject()
        for (key, value) in item {
            switch key {
            case "productName": object.contentMetadata.productName = value as? String
            case "productBrand": object.contentMetadata.productBrand = value as? String
            case "sku": object.contentMetadata.sku = value as? String
            case "price": object.contentMetadata.price = NSDecimalNumber(decimal: (value as? NSNumber ?? 0).decimalValue)
            case "currency": object.contentMetadata.currency = (value as? String).map { BNCCurrency(rawValue: $0) }
            case "quantity": object.contentMetadata.quantity = Double(truncating: value as? NSNumber ?? 0)
            default: object.contentMetadata.customMetadata[key] = value
            }
        }
        return object
    }

    func colorWithHexString(hexString: String, alpha: CGFloat = 1.0) -> UIColor {
        let hexint = Int(intFromHexString(hexStr: hexString))
        return UIColor(
            red: CGFloat((hexint & 0xff0000) >> 16) / 255.0,
            green: CGFloat((hexint & 0xff00) >> 8) / 255.0,
            blue: CGFloat((hexint & 0xff) >> 0) / 255.0,
            alpha: alpha
        )
    }

    func intFromHexString(hexStr: String) -> UInt32 {
        let scanner = Scanner(string: hexStr)
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: "#")
        return UInt32(bitPattern: scanner.scanInt32(representation: .hexadecimal) ?? 0)
    }
}
