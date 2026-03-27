import IOKit.pwr_mgt

class SleepManager {
    private var assertionID: IOPMAssertionID = 0
    private var isPreventingSleep = false

    func preventSleep() {
        guard !isPreventingSleep else { return }
        let reason = "Claude Code is working" as CFString
        let assertionType = kIOPMAssertionTypePreventUserIdleSystemSleep as CFString
        let result = IOPMAssertionCreateWithName(
            assertionType,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        )
        isPreventingSleep = (result == kIOReturnSuccess)
    }

    func allowSleep() {
        guard isPreventingSleep else { return }
        IOPMAssertionRelease(assertionID)
        isPreventingSleep = false
    }

    deinit {
        allowSleep()
    }
}
