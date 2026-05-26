import Foundation
import CoreGraphics
import ScreenCaptureKit

public enum ScreenCaptureError: Error {
    case permissionDenied
    case noFrontmostWindow
    case captureFailed(Error)
}

public struct ScreenCapture: Sendable {
    public let image: CGImage
    /// Frame of the window we captured, in screen coordinates (Quartz, top-left).
    /// Used by the OCR layer to project the focused-field rect into the
    /// captured image's coordinate system so we can mask it out.
    public let windowFrame: CGRect
}

/// One-shot screenshot of the frontmost window of a given app, downscaled
/// to a width budget so the OCR stage stays under its latency target.
public actor ScreenCapturer {
    public static let maxWidth: Int = 1280

    public init() {}

    public static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Requests Screen Recording permission. The first call shows the system
    /// prompt; subsequent calls just return the current state.
    @discardableResult
    public static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Forces macOS to register this app in TCC and show the permission
    /// prompt. Plain `CGRequestScreenCaptureAccess()` is unreliable: when
    /// the app has never been TCC-registered (typical first launch from
    /// `open` or Finder), the call returns immediately with no prompt and
    /// the app stays invisible in System Settings > Privacy > Screen
    /// Recording. The reliable trick is to actually hit ScreenCaptureKit
    /// — `SCShareableContent.excludingDesktopWindows` triggers the same
    /// privacy check that capture would, which forces TCC to register
    /// the bundle AND surfaces the system prompt the first time.
    public static func forcePermissionPrompt() async {
        _ = CGRequestScreenCaptureAccess()
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            // Expected when permission is denied — the side effect of
            // registering the bundle in TCC is what we wanted anyway.
        }
    }

    /// Captures the largest on-screen window owned by `bundleID`, returning
    /// the image and the window's screen-coordinate frame for projection.
    public func capture(bundleID: String) async throws -> ScreenCapture {
        guard Self.hasPermission() else { throw ScreenCaptureError.permissionDenied }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw ScreenCaptureError.captureFailed(error)
        }

        let candidates = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == bundleID
        }
        guard let window = candidates.max(by: {
            ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height)
        }) else {
            throw ScreenCaptureError.noFrontmostWindow
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let aspectRatio = window.frame.height / max(window.frame.width, 1)
        let width = min(Int(window.frame.width), Self.maxWidth)
        let height = max(1, Int(Double(width) * aspectRatio))
        config.width = width
        config.height = height
        config.showsCursor = false
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            return ScreenCapture(image: image, windowFrame: window.frame)
        } catch {
            throw ScreenCaptureError.captureFailed(error)
        }
    }
}
