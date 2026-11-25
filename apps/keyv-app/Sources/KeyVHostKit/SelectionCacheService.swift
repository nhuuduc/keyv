import AppKit
import ApplicationServices
import Foundation

public final class SelectionCacheService {
    public static let shared = SelectionCacheService()

    public static let spotlightLikeBundleIDs: Set<String> = [
        "com.apple.Spotlight",
        "com.raycast.macos",
        "com.runningwithcrayons.Alfred",
    ]

    private static let cacheTTLNs: UInt64 = 30_000_000_000
    private static let axTimeoutSeconds: Float = 0.001
    private static let autocompleteRoles: Set<String> = [
        "AXTextField",
        "AXComboBox",
        "AXSearchField",
    ]

    private struct CachedFocus {
        let timestampNs: UInt64
        let fallbackPID: pid_t
        let resolvedPID: pid_t
        let resolvedBundleID: String?
        let needsAutocompleteSpacer: Bool?
        let isSecureTextField: Bool
    }

    private var cached: CachedFocus?

    private init() {}

    public func invalidate() {
        cached = nil
    }

    public func resolveFocusedOverlayApp(
        currentPID: pid_t,
        currentBundleID: String?
    ) -> (pid: pid_t, bundleID: String?) {
        let info = queryFocus(fallbackPID: currentPID, fallbackBundleID: currentBundleID)
        if let bundle = info.resolvedBundleID, Self.spotlightLikeBundleIDs.contains(bundle) {
            return (info.resolvedPID, bundle)
        }
        return (currentPID, currentBundleID)
    }

    public func shouldUseAutocompleteSpacer(pid: pid_t, bundleID: String?) -> Bool? {
        let info = queryFocus(fallbackPID: pid, fallbackBundleID: bundleID)
        return info.needsAutocompleteSpacer
    }

    public func isFocusedElementSecureTextField(pid: pid_t, bundleID: String?) -> Bool {
        let info = queryFocus(fallbackPID: pid, fallbackBundleID: bundleID)
        return info.isSecureTextField
    }

    public func hasActiveAutocompleteSelection(pid: pid_t, bundleID: String?) -> Bool {
        let info = queryFocus(fallbackPID: pid, fallbackBundleID: bundleID)
        guard info.needsAutocompleteSpacer == true, AXIsProcessTrusted() else {
            return false
        }
        let sysWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sysWide, Self.axTimeoutSeconds)
        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            sysWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard err == .success, let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return false
        }
        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, Self.axTimeoutSeconds)
        guard let selected = Self.copyStringAttribute(element, kAXSelectedTextAttribute as CFString) else {
            return false
        }
        return !selected.isEmpty
    }

    private func queryFocus(fallbackPID: pid_t, fallbackBundleID: String?) -> CachedFocus {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        if let cached,
           cached.fallbackPID == fallbackPID,
           (nowNs &- cached.timestampNs) <= Self.cacheTTLNs {
            return cached
        }

        guard AXIsProcessTrusted() else {
            let entry = CachedFocus(
                timestampNs: nowNs,
                fallbackPID: fallbackPID,
                resolvedPID: fallbackPID,
                resolvedBundleID: fallbackBundleID,
                needsAutocompleteSpacer: nil,
                isSecureTextField: false
            )
            cached = entry
            return entry
        }

        let sysWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sysWide, Self.axTimeoutSeconds)

        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            sysWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard err == .success, let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            let entry = CachedFocus(
                timestampNs: nowNs,
                fallbackPID: fallbackPID,
                resolvedPID: fallbackPID,
                resolvedBundleID: fallbackBundleID,
                needsAutocompleteSpacer: nil,
                isSecureTextField: false
            )
            cached = entry
            return entry
        }

        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, Self.axTimeoutSeconds)
        let subrole = Self.copyStringAttribute(element, kAXSubroleAttribute as CFString)
        let isSecure = (subrole == (kAXSecureTextFieldSubrole as String))

        var elemPID: pid_t = 0
        AXUIElementGetPid(element, &elemPID)
        let resolvedPID = elemPID > 0 ? elemPID : fallbackPID
        let resolvedBundleID: String?
        if elemPID > 0 && elemPID != fallbackPID {
            resolvedBundleID = NSRunningApplication(processIdentifier: elemPID)?.bundleIdentifier
                ?? fallbackBundleID
        } else {
            resolvedBundleID = fallbackBundleID
        }

        let bundle = resolvedBundleID ?? ""
        let needsSpacer: Bool
        if EventInjector.terminalBundleIDs.contains(bundle) {
            needsSpacer = false
        } else if Self.spotlightLikeBundleIDs.contains(bundle) || bundle == "com.microsoft.Excel" {
            needsSpacer = true
        } else if EventInjector.compatBundleIDs.contains(bundle) {
            needsSpacer = Self.isBrowserNativeAutocompleteField(element)
        } else {
            needsSpacer = false
        }

        let entry = CachedFocus(
            timestampNs: nowNs,
            fallbackPID: fallbackPID,
            resolvedPID: resolvedPID,
            resolvedBundleID: resolvedBundleID,
            needsAutocompleteSpacer: needsSpacer,
            isSecureTextField: isSecure
        )
        cached = entry
        return entry
    }

    private static func isBrowserNativeAutocompleteField(_ element: AXUIElement) -> Bool {
        guard let role = copyStringAttribute(element, kAXRoleAttribute as CFString),
              autocompleteRoles.contains(role)
        else {
            return false
        }

        var cursor: AXUIElement? = element
        for _ in 0..<5 {
            guard let current = cursor else { break }
            AXUIElementSetMessagingTimeout(current, axTimeoutSeconds)
            if let r = copyStringAttribute(current, kAXRoleAttribute as CFString), r == "AXWebArea" {
                return false
            }
            var parentRef: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(
                current,
                kAXParentAttribute as CFString,
                &parentRef
            )
            if err == .success, let parentRef, CFGetTypeID(parentRef) == AXUIElementGetTypeID() {
                cursor = (parentRef as! AXUIElement)
            } else {
                break
            }
        }
        return true
    }

    private static func copyStringAttribute(_ element: AXUIElement, _ attr: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
