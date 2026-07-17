//
//  ShieldActionExtension.swift
//  GetuppShieldAction
//
//  Handles taps on the shield's button — clearing layer 3 (self-heal).
//
//  iOS DeviceActivity callbacks can run late or never (known reliability issue).
//  If layer 1 misses the timeout end, the user's next instinct is to tap the
//  blocked app: this handler asks the same question every other layer asks
//  ("is timeoutEndTime elapsed?") and clears the shields right here if so —
//  a missed callback never locks anyone out past their time.
//
//  The response is ALWAYS .close: closing the blocked app is the only thing a
//  shield button can do (iOS restriction — it cannot open GETUPP). During the
//  morning block and mid-timeout this is identical to the old behavior.
//
//  Kept minimal: needs only Timeout.swift (Foundation + ManagedSettings).
//

import Foundation
import ManagedSettings

class ShieldActionExtension: ShieldActionDelegate {

    override func handle(action: ShieldAction, for application: ApplicationToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {
        completionHandler(respond(to: action))
    }

    override func handle(action: ShieldAction, for webDomain: WebDomainToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {
        completionHandler(respond(to: action))
    }

    override func handle(action: ShieldAction, for category: ActivityCategoryToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {
        completionHandler(respond(to: action))
    }

    /// One path for every token type and both buttons: run the shared elapsed
    /// check (idempotent — a no-op if another layer already completed it), then
    /// close the blocked app. If the timeout just completed, the app the user
    /// tapped reopens unblocked on the next launch.
    private func respond(to action: ShieldAction) -> ShieldActionResponse {
        Timeout.completeTimeoutIfElapsed()
        return .close
    }
}
