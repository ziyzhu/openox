import Foundation
@preconcurrency import HealthKit

@MainActor
final class HealthProvider {
    static let shared = HealthProvider()

    enum AuthorizationRequestState: Equatable {
        case unavailable
        case shouldRequest
        case unnecessary
    }

    struct ActivityDay: Encodable {
        let date: String
        let steps: Int?
        let activeEnergyKcal: Double?
        let exerciseMinutes: Int?
        let walkingRunningDistanceMeters: Int?
    }

    struct ActivitySummary: Encodable {
        let start: String
        let end: String
        let timezone: String
        let days: [ActivityDay]
    }

    struct SleepDay: Encodable {
        let date: String
        let inBedMinutes: Int?
        let asleepMinutes: Int?
        let awakeMinutes: Int?
        let coreMinutes: Int?
        let deepMinutes: Int?
        let remMinutes: Int?
    }

    struct SleepSummary: Encodable {
        let start: String
        let end: String
        let timezone: String
        let days: [SleepDay]
    }

    struct WorkoutRecord: Encodable {
        let activity: String
        let activityTypeCode: UInt
        let start: String
        let end: String
        let durationMinutes: Double
        let activeEnergyKcal: Double?
        let distanceMeters: Double?
    }

    struct WorkoutsSummary: Encodable {
        let start: String
        let end: String
        let workouts: [WorkoutRecord]
        let truncated: Bool
    }

    struct VitalsDay: Encodable {
        let date: String
        let restingHeartRateBpm: Double?
        let heartRateVariabilityMs: Double?
        let respiratoryRatePerMinute: Double?
    }

    struct VitalsSummary: Encodable {
        let start: String
        let end: String
        let timezone: String
        let days: [VitalsDay]
    }

    struct BodyDay: Encodable {
        let date: String
        let weightKg: Double?
        let bodyFatPercent: Double?
        let leanBodyMassKg: Double?
    }

    struct BodySummary: Encodable {
        let start: String
        let end: String
        let timezone: String
        let days: [BodyDay]
    }

    enum HealthError: LocalizedError {
        case unavailable
        case authorization(String)
        case query(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "Apple Health data isn't available on this device."
            case .authorization(let reason):
                "Apple Health access couldn't be requested: \(reason)"
            case .query(let reason):
                "Apple Health data couldn't be read: \(reason)"
            }
        }
    }

    private struct Metric {
        let type: HKQuantityType
        let unit: HKUnit
    }

    private let store = HKHealthStore()

    private init() {}

    func authorizationRequestState() async -> AuthorizationRequestState {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        return await withCheckedContinuation { continuation in
            store.getRequestStatusForAuthorization(toShare: [], read: Self.readTypes) { status, error in
                if let error {
                    Log.agent.error("health.auth status failed \(error.localizedDescription)")
                    continuation.resume(returning: .unavailable)
                    return
                }
                switch status {
                case .shouldRequest: continuation.resume(returning: .shouldRequest)
                case .unnecessary: continuation.resume(returning: .unnecessary)
                case .unknown: continuation.resume(returning: .unavailable)
                @unknown default: continuation.resume(returning: .unavailable)
                }
            }
        }
    }

    func requestAccess() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthError.unavailable }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.requestAuthorization(toShare: [], read: Self.readTypes) { success, error in
                if let error {
                    continuation.resume(throwing: HealthError.authorization(error.localizedDescription))
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: HealthError.authorization("the request didn't complete"))
                }
            }
        }
    }

    func activity(start: Date, end: Date) async throws -> ActivitySummary {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthError.unavailable }
        try await requestAccessIfNeeded()

        async let stepsQuery = dailySums(metric: Self.steps, start: start, end: end)
        async let energyQuery = dailySums(metric: Self.activeEnergy, start: start, end: end)
        async let exerciseQuery = dailySums(metric: Self.exerciseTime, start: start, end: end)
        async let distanceQuery = dailySums(metric: Self.walkingRunningDistance, start: start, end: end)
        let (steps, energy, exercise, distance) = try await (stepsQuery, energyQuery, exerciseQuery, distanceQuery)
        let calendar = Calendar.autoupdatingCurrent
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        var days: [ActivityDay] = []
        var day = calendar.startOfDay(for: start)
        while day < end {
            days.append(ActivityDay(
                date: formatter.string(from: day),
                steps: steps[day].map { Int($0.rounded()) },
                activeEnergyKcal: energy[day].map { Self.round($0, places: 1) },
                exerciseMinutes: exercise[day].map { Int($0.rounded()) },
                walkingRunningDistanceMeters: distance[day].map { Int($0.rounded()) }
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        let visibleMetrics = days.reduce(0) { count, day in
            count
                + (day.steps == nil ? 0 : 1)
                + (day.activeEnergyKcal == nil ? 0 : 1)
                + (day.exerciseMinutes == nil ? 0 : 1)
                + (day.walkingRunningDistanceMeters == nil ? 0 : 1)
        }
        Log.agent.info("health.activity days=\(days.count) visibleMetrics=\(visibleMetrics)")
        return ActivitySummary(
            start: ISODate.string(from: start),
            end: ISODate.string(from: end),
            timezone: calendar.timeZone.identifier,
            days: days
        )
    }

    func sleep(start: Date, end: Date) async throws -> SleepSummary {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthError.unavailable }
        try await requestAccessIfNeeded()

        let samples: [HKCategorySample] = try await samples(
            type: Self.sleepAnalysis,
            start: start,
            end: end,
            options: []
        )
        let (calendar, formatter, dates) = Self.dateSeries(start: start, end: end)
        let days = dates.map { day in
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) ?? end
            return SleepDay(
                date: formatter.string(from: day),
                inBedMinutes: Self.durationMinutes(samples, values: Self.inBedValues, start: day, end: dayEnd),
                asleepMinutes: Self.durationMinutes(samples, values: Self.asleepValues, start: day, end: dayEnd),
                awakeMinutes: Self.durationMinutes(samples, values: Self.awakeValues, start: day, end: dayEnd),
                coreMinutes: Self.durationMinutes(samples, values: Self.coreValues, start: day, end: dayEnd),
                deepMinutes: Self.durationMinutes(samples, values: Self.deepValues, start: day, end: dayEnd),
                remMinutes: Self.durationMinutes(samples, values: Self.remValues, start: day, end: dayEnd)
            )
        }
        let visibleMetrics = days.reduce(0) { count, day in
            count
                + (day.inBedMinutes == nil ? 0 : 1)
                + (day.asleepMinutes == nil ? 0 : 1)
                + (day.awakeMinutes == nil ? 0 : 1)
                + (day.coreMinutes == nil ? 0 : 1)
                + (day.deepMinutes == nil ? 0 : 1)
                + (day.remMinutes == nil ? 0 : 1)
        }
        Log.agent.info("health.sleep days=\(days.count) samples=\(samples.count) visibleMetrics=\(visibleMetrics)")
        return SleepSummary(
            start: ISODate.string(from: start),
            end: ISODate.string(from: end),
            timezone: calendar.timeZone.identifier,
            days: days
        )
    }

    func workouts(start: Date, end: Date) async throws -> WorkoutsSummary {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthError.unavailable }
        try await requestAccessIfNeeded()

        let samples: [HKWorkout] = try await samples(
            type: .workoutType(),
            start: start,
            end: end,
            limit: 201,
            ascending: false
        )
        let truncated = samples.count > 200
        let workouts = samples.prefix(200).reversed().map { workout in
            WorkoutRecord(
                activity: Self.workoutName(workout.workoutActivityType),
                activityTypeCode: workout.workoutActivityType.rawValue,
                start: ISODate.string(from: workout.startDate),
                end: ISODate.string(from: workout.endDate),
                durationMinutes: Self.round(workout.duration / 60, places: 1),
                activeEnergyKcal: workout.statistics(for: Self.activeEnergy.type)?.sumQuantity().map {
                    Self.round($0.doubleValue(for: Self.activeEnergy.unit), places: 1)
                },
                distanceMeters: Self.workoutDistance(workout).map { Self.round($0, places: 1) }
            )
        }
        Log.agent.info("health.workouts count=\(workouts.count) truncated=\(truncated)")
        return WorkoutsSummary(
            start: ISODate.string(from: start),
            end: ISODate.string(from: end),
            workouts: Array(workouts),
            truncated: truncated
        )
    }

    func vitals(start: Date, end: Date) async throws -> VitalsSummary {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthError.unavailable }
        try await requestAccessIfNeeded()

        async let restingHeartRateQuery = dailyAverages(metric: Self.restingHeartRate, start: start, end: end)
        async let heartRateVariabilityQuery = dailyAverages(metric: Self.heartRateVariability, start: start, end: end)
        async let respiratoryRateQuery = dailyAverages(metric: Self.respiratoryRate, start: start, end: end)
        let (restingHeartRate, heartRateVariability, respiratoryRate) = try await (
            restingHeartRateQuery,
            heartRateVariabilityQuery,
            respiratoryRateQuery
        )
        let (calendar, formatter, dates) = Self.dateSeries(start: start, end: end)
        let days = dates.map { day in
            VitalsDay(
                date: formatter.string(from: day),
                restingHeartRateBpm: restingHeartRate[day].map { Self.round($0, places: 1) },
                heartRateVariabilityMs: heartRateVariability[day].map { Self.round($0, places: 1) },
                respiratoryRatePerMinute: respiratoryRate[day].map { Self.round($0, places: 1) }
            )
        }
        let visibleMetrics = days.reduce(0) { count, day in
            count
                + (day.restingHeartRateBpm == nil ? 0 : 1)
                + (day.heartRateVariabilityMs == nil ? 0 : 1)
                + (day.respiratoryRatePerMinute == nil ? 0 : 1)
        }
        Log.agent.info("health.vitals days=\(days.count) visibleMetrics=\(visibleMetrics)")
        return VitalsSummary(
            start: ISODate.string(from: start),
            end: ISODate.string(from: end),
            timezone: calendar.timeZone.identifier,
            days: days
        )
    }

    func body(start: Date, end: Date) async throws -> BodySummary {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthError.unavailable }
        try await requestAccessIfNeeded()

        async let weightQuery = dailyLatest(metric: Self.bodyMass, start: start, end: end)
        async let bodyFatQuery = dailyLatest(metric: Self.bodyFatPercentage, start: start, end: end)
        async let leanBodyMassQuery = dailyLatest(metric: Self.leanBodyMass, start: start, end: end)
        let (weight, bodyFat, leanBodyMass) = try await (weightQuery, bodyFatQuery, leanBodyMassQuery)
        let (calendar, formatter, dates) = Self.dateSeries(start: start, end: end)
        let days = dates.map { day in
            BodyDay(
                date: formatter.string(from: day),
                weightKg: weight[day].map { Self.round($0, places: 2) },
                bodyFatPercent: bodyFat[day].map { Self.round($0, places: 1) },
                leanBodyMassKg: leanBodyMass[day].map { Self.round($0, places: 2) }
            )
        }
        let visibleMetrics = days.reduce(0) { count, day in
            count
                + (day.weightKg == nil ? 0 : 1)
                + (day.bodyFatPercent == nil ? 0 : 1)
                + (day.leanBodyMassKg == nil ? 0 : 1)
        }
        Log.agent.info("health.body days=\(days.count) visibleMetrics=\(visibleMetrics)")
        return BodySummary(
            start: ISODate.string(from: start),
            end: ISODate.string(from: end),
            timezone: calendar.timeZone.identifier,
            days: days
        )
    }

    private func requestAccessIfNeeded() async throws {
        switch await authorizationRequestState() {
        case .shouldRequest:
            Log.agent.info("health.auth request=needed")
            try await requestAccess()
        case .unnecessary:
            Log.agent.info("health.auth request=unnecessary")
        case .unavailable:
            throw HealthError.unavailable
        }
    }

    private func dailySums(metric: Metric, start: Date, end: Date) async throws -> [Date: Double] {
        let calendar = Calendar.autoupdatingCurrent
        let anchor = calendar.startOfDay(for: start)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: metric.type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: anchor,
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, collection, error in
                if let error {
                    continuation.resume(throwing: HealthError.query(error.localizedDescription))
                    return
                }
                let values = collection?.statistics().reduce(into: [Date: Double]()) { result, statistics in
                    guard let sum = statistics.sumQuantity() else { return }
                    result[calendar.startOfDay(for: statistics.startDate)] = sum.doubleValue(for: metric.unit)
                } ?? [:]
                continuation.resume(returning: values)
            }
            store.execute(query)
        }
    }

    private func dailyAverages(metric: Metric, start: Date, end: Date) async throws -> [Date: Double] {
        let calendar = Calendar.autoupdatingCurrent
        let anchor = calendar.startOfDay(for: start)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: metric.type,
                quantitySamplePredicate: predicate,
                options: .discreteAverage,
                anchorDate: anchor,
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, collection, error in
                if let error {
                    continuation.resume(throwing: HealthError.query(error.localizedDescription))
                    return
                }
                let values = collection?.statistics().reduce(into: [Date: Double]()) { result, statistics in
                    guard let average = statistics.averageQuantity() else { return }
                    result[calendar.startOfDay(for: statistics.startDate)] = average.doubleValue(for: metric.unit)
                } ?? [:]
                continuation.resume(returning: values)
            }
            store.execute(query)
        }
    }

    private func dailyLatest(metric: Metric, start: Date, end: Date) async throws -> [Date: Double] {
        let samples: [HKQuantitySample] = try await samples(type: metric.type, start: start, end: end)
        let calendar = Calendar.autoupdatingCurrent
        return samples.reduce(into: [Date: (Date, Double)]()) { result, sample in
            let day = calendar.startOfDay(for: sample.startDate)
            let existingDate = result[day]?.0 ?? .distantPast
            guard existingDate <= sample.startDate else { return }
            result[day] = (sample.startDate, sample.quantity.doubleValue(for: metric.unit))
        }.mapValues(\.1)
    }

    private func samples<Sample: HKSample>(
        type: HKSampleType,
        start: Date,
        end: Date,
        limit: Int = HKObjectQueryNoLimit,
        options: HKQueryOptions = .strictStartDate,
        ascending: Bool = true
    ) async throws -> [Sample] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: options)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: ascending)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: limit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: HealthError.query(error.localizedDescription))
                    return
                }
                guard let typed = samples as? [Sample] else {
                    continuation.resume(throwing: HealthError.query("HealthKit returned an unexpected sample type"))
                    return
                }
                continuation.resume(returning: typed)
            }
            store.execute(query)
        }
    }

    private static func dateSeries(start: Date, end: Date) -> (Calendar, DateFormatter, [Date]) {
        let calendar = Calendar.autoupdatingCurrent
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        var dates: [Date] = []
        var day = calendar.startOfDay(for: start)
        while day < end {
            dates.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return (calendar, formatter, dates)
    }

    private static func durationMinutes(
        _ samples: [HKCategorySample],
        values: Set<Int>,
        start: Date,
        end: Date
    ) -> Int? {
        let intervals = samples.compactMap { sample -> DateInterval? in
            guard values.contains(sample.value) else { return nil }
            let lower = max(start, sample.startDate)
            let upper = min(end, sample.endDate)
            return upper > lower ? DateInterval(start: lower, end: upper) : nil
        }.sorted { $0.start < $1.start }
        guard var current = intervals.first else { return nil }
        var seconds: TimeInterval = 0
        for interval in intervals.dropFirst() {
            if interval.start <= current.end {
                current = DateInterval(start: current.start, end: max(current.end, interval.end))
            } else {
                seconds += current.duration
                current = interval
            }
        }
        seconds += current.duration
        return Int((seconds / 60).rounded())
    }

    private static func workoutDistance(_ workout: HKWorkout) -> Double? {
        workout.allStatistics.compactMap { type, statistics -> Double? in
            guard type.identifier.localizedCaseInsensitiveContains("distance"),
                  let quantity = statistics.sumQuantity() else { return nil }
            return quantity.doubleValue(for: .meter())
        }.max()
    }

    private static func workoutName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .walking: "walking"
        case .running: "running"
        case .cycling: "cycling"
        case .swimming: "swimming"
        case .hiking: "hiking"
        case .yoga: "yoga"
        case .rowing: "rowing"
        case .elliptical: "elliptical"
        case .stairClimbing: "stair climbing"
        case .traditionalStrengthTraining: "traditional strength training"
        case .functionalStrengthTraining: "functional strength training"
        case .highIntensityIntervalTraining: "high intensity interval training"
        case .pilates: "pilates"
        case .coreTraining: "core training"
        case .dance: "dance"
        case .cooldown: "cooldown"
        case .mixedCardio: "mixed cardio"
        case .crossTraining: "cross training"
        case .flexibility: "flexibility"
        case .mindAndBody: "mind and body"
        default: "other"
        }
    }

    private static func round(_ value: Double, places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }

    private static let steps = Metric(
        type: HKQuantityType(.stepCount),
        unit: .count()
    )

    private static let activeEnergy = Metric(
        type: HKQuantityType(.activeEnergyBurned),
        unit: .kilocalorie()
    )

    private static let exerciseTime = Metric(
        type: HKQuantityType(.appleExerciseTime),
        unit: .minute()
    )

    private static let walkingRunningDistance = Metric(
        type: HKQuantityType(.distanceWalkingRunning),
        unit: .meter()
    )

    private static let restingHeartRate = Metric(
        type: HKQuantityType(.restingHeartRate),
        unit: HKUnit.count().unitDivided(by: .minute())
    )

    private static let heartRateVariability = Metric(
        type: HKQuantityType(.heartRateVariabilitySDNN),
        unit: .secondUnit(with: .milli)
    )

    private static let respiratoryRate = Metric(
        type: HKQuantityType(.respiratoryRate),
        unit: HKUnit.count().unitDivided(by: .minute())
    )

    private static let bodyMass = Metric(
        type: HKQuantityType(.bodyMass),
        unit: .gramUnit(with: .kilo)
    )

    private static let bodyFatPercentage = Metric(
        type: HKQuantityType(.bodyFatPercentage),
        unit: .percent()
    )

    private static let leanBodyMass = Metric(
        type: HKQuantityType(.leanBodyMass),
        unit: .gramUnit(with: .kilo)
    )

    private static let sleepAnalysis = HKCategoryType(.sleepAnalysis)

    private static let inBedValues: Set<Int> = [
        HKCategoryValueSleepAnalysis.inBed.rawValue,
    ]

    private static let asleepValues: Set<Int> = [
        HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
        HKCategoryValueSleepAnalysis.asleepCore.rawValue,
        HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
        HKCategoryValueSleepAnalysis.asleepREM.rawValue,
    ]

    private static let awakeValues: Set<Int> = [
        HKCategoryValueSleepAnalysis.awake.rawValue,
    ]

    private static let coreValues: Set<Int> = [
        HKCategoryValueSleepAnalysis.asleepCore.rawValue,
    ]

    private static let deepValues: Set<Int> = [
        HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
    ]

    private static let remValues: Set<Int> = [
        HKCategoryValueSleepAnalysis.asleepREM.rawValue,
    ]

    private static let readTypes: Set<HKObjectType> = [
        steps.type,
        activeEnergy.type,
        exerciseTime.type,
        walkingRunningDistance.type,
        HKQuantityType(.distanceCycling),
        HKQuantityType(.distanceSwimming),
        HKQuantityType(.distanceWheelchair),
        HKQuantityType(.distanceDownhillSnowSports),
        sleepAnalysis,
        HKObjectType.workoutType(),
        restingHeartRate.type,
        heartRateVariability.type,
        respiratoryRate.type,
        bodyMass.type,
        bodyFatPercentage.type,
        leanBodyMass.type,
    ]
}
