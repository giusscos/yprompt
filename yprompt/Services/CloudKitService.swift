//
//  CloudKitService.swift
//  yprompt
//

import Foundation
import CloudKit

// MARK: - SyncStatus
enum SyncStatus: Equatable {
    case idle, syncing, synced, error(String)

    var label: String {
        switch self {
        case .idle:          return "Not synced"
        case .syncing:       return "Syncing…"
        case .synced:        return "Up to date"
        case .error(let m):  return "Error: \(m)"
        }
    }
}

@Observable @MainActor
class CloudKitService {
    var syncStatus: SyncStatus = .idle
    var isAuthenticated = false

    private let container = CKContainer(identifier: "iCloud.com.giusscos.yprompt")
    private var retryCount = 0
    private let maxRetries = 3

    init() {
        Task { await checkAuthentication() }
    }

    // MARK: - Authentication

    func checkAuthentication() async {
        do {
            let status = try await container.accountStatus()
            isAuthenticated = status == .available
        } catch {
            isAuthenticated = false
        }
    }

    // MARK: - Sync

    func syncScript(_ script: Script) async {
        guard isAuthenticated else { return }
        syncStatus = .syncing
        do {
            let record = scriptToRecord(script)
            _ = try await container.privateCloudDatabase.save(record)
            script.cloudSyncState = .synced
            syncStatus = .synced
            retryCount = 0
        } catch {
            script.cloudSyncState = .failed
            if retryCount < maxRetries {
                retryCount += 1
                let delay = Double(retryCount) * 2
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await syncScript(script)
            } else {
                syncStatus = .error(error.localizedDescription)
                retryCount = 0
            }
        }
    }

    // MARK: - Helpers

    private func scriptToRecord(_ script: Script) -> CKRecord {
        let recordID = CKRecord.ID(recordName: script.id.uuidString)
        let record = CKRecord(recordType: "Script", recordID: recordID)
        record["title"] = script.title
        record["content"] = script.content
        record["modifiedAt"] = script.modifiedAt
        record["isFavorite"] = script.isFavorite ? 1 : 0
        if let data = script.customizationData {
            record["customizationData"] = data as CKRecordValue
        }
        return record
    }
}
