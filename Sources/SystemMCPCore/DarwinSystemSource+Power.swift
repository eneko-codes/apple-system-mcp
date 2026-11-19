import Foundation
import IOKit
import IOKit.ps

/// Power sources through the documented IOPowerSources interface (`IOKit/ps/IOPowerSources.h`
/// and `IOPSKeys.h`). The keys are the SDK's own constants; the registry behind them, where
/// the battery's cycle count and serial number live under undocumented names, is not read.
extension DarwinSystemSource {

    public func powerStatus() throws -> PowerStatus {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            throw SystemSourceError.callFailed(function: "IOPSCopyPowerSourcesInfo", code: -1)
        }
        // A desktop answers with an empty list, which is an answer and not a failure.
        let sources = (IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]) ?? []
        let descriptions = sources.compactMap { source in
            IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any]
        }
        return PowerStatus(
            providing: IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?,
            sources: descriptions.compactMap(Self.powerSource(from:)))
    }

    /// Pure over the dictionary the system returns, so the tests feed it invented values.
    /// Takes only the keys listed here: the hardware serial number and vendor data in the
    /// same dictionary are never read.
    static func powerSource(from description: [String: Any]) -> PowerSource? {
        guard let name = description[kIOPSNameKey] as? String else { return nil }
        func integer(_ key: String) -> Int? { (description[key] as? NSNumber)?.intValue }
        func flag(_ key: String) -> Bool? { (description[key] as? NSNumber)?.boolValue }
        return PowerSource(
            name: name, kind: description[kIOPSTypeKey] as? String,
            state: description[kIOPSPowerSourceStateKey] as? String,
            isPresent: flag(kIOPSIsPresentKey) ?? true, isCharging: flag(kIOPSIsChargingKey) ?? false,
            isCharged: flag(kIOPSIsChargedKey) ?? false,
            currentCapacity: integer(kIOPSCurrentCapacityKey), maxCapacity: integer(kIOPSMaxCapacityKey),
            timeToEmptyMinutes: integer(kIOPSTimeToEmptyKey),
            timeToFullMinutes: integer(kIOPSTimeToFullChargeKey),
            health: description[kIOPSBatteryHealthKey] as? String,
            healthCondition: description[kIOPSBatteryHealthConditionKey] as? String,
            temperatureCelsius: integer(kIOPSTemperatureKey),
            voltageMillivolts: integer(kIOPSVoltageKey), currentMilliamps: integer(kIOPSCurrentKey),
            hasInternalFailure: flag(kIOPSInternalFailureKey) ?? false)
    }
}
