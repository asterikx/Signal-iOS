//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation
import SignalServiceKit
import CloudKit
import PromiseKit

// We don't worry about atomic writes.  Each backup export
// will diff against last successful backup.
//
// Note that all of our CloudKit records are immutable.
// "Persistent" records are only uploaded once.
// "Ephemeral" records are always uploaded to a new record name.
@objc public class OWSBackupAPI: NSObject {

    // If we change the record types, we need to ensure indices
    // are configured properly in the CloudKit dashboard.
    //
    // TODO: Change the record types when we ship to production.
    static let signalBackupRecordType = "signalBackup"
    static let manifestRecordNameSuffix = "manifest"
    static let payloadKey = "payload"
    static let maxRetries = 5

    private class func recordIdForTest() -> String {
        return "test-\(NSUUID().uuidString)"
    }

    private class func database() -> CKDatabase {
        let myContainer = CKContainer.default()
        let privateDatabase = myContainer.privateCloudDatabase
        return privateDatabase
    }

    private class func invalidServiceResponseError() -> Error {
        return OWSErrorWithCodeDescription(.backupFailure,
                                           NSLocalizedString("BACKUP_EXPORT_ERROR_INVALID_CLOUDKIT_RESPONSE",
                                                             comment: "Error indicating that the app received an invalid response from CloudKit."))
    }

    // MARK: - Upload

    @objc
    public class func saveTestFileToCloudObjc(recipientId: String,
                                              fileUrl: URL) -> AnyPromise {
        return AnyPromise(saveTestFileToCloud(recipientId: recipientId,
                                              fileUrl: fileUrl))
    }

    public class func saveTestFileToCloud(recipientId: String,
                                          fileUrl: URL) -> Promise<String> {
        let recordName = "\(recordNamePrefix(forRecipientId: recipientId))test-\(NSUUID().uuidString)"
        return saveFileToCloud(fileUrl: fileUrl,
                               recordName: recordName,
                               recordType: signalBackupRecordType)
    }

    // "Ephemeral" files are specific to this backup export and will always need to
    // be saved.  For example, a complete image of the database is exported each time.
    // We wouldn't want to overwrite previous images until the entire backup export is
    // complete.
    @objc
    public class func saveEphemeralFileToCloudObjc(recipientId: String,
                                                   fileUrl: URL) -> AnyPromise {
        return AnyPromise(saveEphemeralFileToCloud(recipientId: recipientId,
                                                   fileUrl: fileUrl))
    }

    public class func saveEphemeralFileToCloud(recipientId: String,
                                               fileUrl: URL) -> Promise<String> {
        let recordName = "\(recordNamePrefix(forRecipientId: recipientId))ephemeralFile-\(NSUUID().uuidString)"
        return saveFileToCloud(fileUrl: fileUrl,
                               recordName: recordName,
                               recordType: signalBackupRecordType)
    }

    // "Persistent" files may be shared between backup export; they should only be saved
    // once.  For example, attachment files should only be uploaded once.  Subsequent
    // backups can reuse the same record.
    @objc
    public class func recordNameForPersistentFile(recipientId: String,
                                                  fileId: String) -> String {
        return "\(recordNamePrefix(forRecipientId: recipientId))persistentFile-\(fileId)"
    }

    // "Persistent" files may be shared between backup export; they should only be saved
    // once.  For example, attachment files should only be uploaded once.  Subsequent
    // backups can reuse the same record.
    @objc
    public class func recordNameForManifest(recipientId: String) -> String {
        return "\(recordNamePrefix(forRecipientId: recipientId))\(manifestRecordNameSuffix)"
    }

    private class func isManifest(recordName: String) -> Bool {
        return recordName.hasSuffix(manifestRecordNameSuffix)
    }

    private class func recordNamePrefix(forRecipientId recipientId: String) -> String {
        return "\(recipientId)-"
    }

    private class func recipientId(forRecordName recordName: String) -> String? {
        let recipientIds = self.recipientIds(forRecordNames: [recordName])
        guard let recipientId = recipientIds.first else {
            return nil
        }
        return recipientId
    }

    private static var recordNamePrefixRegex = {
        return try! NSRegularExpression(pattern: "^(\\+[0-9]+)\\-")
    }()

    private class func recipientIds(forRecordNames recordNames: [String]) -> [String] {
        var recipientIds = [String]()
        for recordName in recordNames {
            let regex = recordNamePrefixRegex
            guard let match: NSTextCheckingResult = regex.firstMatch(in: recordName, options: [], range: NSRange(location: 0, length: recordName.count)) else {
                Logger.warn("no match: \(recordName)")
                continue
            }
            guard match.numberOfRanges > 0 else {
                // Match must include first group.
                Logger.warn("invalid match: \(recordName)")
                continue
            }
            let firstRange = match.range(at: 1)
            guard firstRange.location == 0,
                firstRange.length > 0 else {
                    // Match must be at start of string and non-empty.
                    Logger.warn("invalid match: \(recordName) \(firstRange)")
                    continue
            }
            let recipientId = (recordName as NSString).substring(with: firstRange) as String
            recipientIds.append(recipientId)
        }
        return recipientIds
    }

    // "Persistent" files may be shared between backup export; they should only be saved
    // once.  For example, attachment files should only be uploaded once.  Subsequent
    // backups can reuse the same record.
    @objc
    public class func savePersistentFileOnceToCloudObjc(recipientId: String,
                                                        fileId: String,
                                                        fileUrlBlock: @escaping () -> URL?) -> AnyPromise {
        return AnyPromise(savePersistentFileOnceToCloud(recipientId: recipientId,
                                                        fileId: fileId,
                                                        fileUrlBlock: fileUrlBlock))
    }

    public class func savePersistentFileOnceToCloud(recipientId: String,
                                                    fileId: String,
                                                    fileUrlBlock: @escaping () -> URL?) -> Promise<String> {
        let recordName = recordNameForPersistentFile(recipientId: recipientId, fileId: fileId)
        return saveFileOnceToCloud(recordName: recordName,
                                   recordType: signalBackupRecordType,
                                   fileUrlBlock: fileUrlBlock)
    }

    @objc
    public class func upsertManifestFileToCloudObjc(recipientId: String,
                                                    fileUrl: URL) -> AnyPromise {
        return AnyPromise(upsertManifestFileToCloud(recipientId: recipientId,
                                                    fileUrl: fileUrl))
    }

    public class func upsertManifestFileToCloud(recipientId: String,
                                                fileUrl: URL) -> Promise<String> {
        // We want to use a well-known record id and type for manifest files.
        let recordName = recordNameForManifest(recipientId: recipientId)
        return upsertFileToCloud(fileUrl: fileUrl,
                                 recordName: recordName,
                                 recordType: signalBackupRecordType)
    }

    @objc
    public class func saveFileToCloudObjc(fileUrl: URL,
                                          recordName: String,
                                          recordType: String) -> AnyPromise {
        return AnyPromise(saveFileToCloud(fileUrl: fileUrl,
                                          recordName: recordName,
                                          recordType: recordType))
    }

    public class func saveFileToCloud(fileUrl: URL,
                                      recordName: String,
                                      recordType: String) -> Promise<String> {
        let recordID = CKRecordID(recordName: recordName)
        let record = CKRecord(recordType: recordType, recordID: recordID)
        let asset = CKAsset(fileURL: fileUrl)
        record[payloadKey] = asset

        return saveRecordToCloud(record: record)
    }

    @objc
    public class func saveRecordToCloudObjc(record: CKRecord) -> AnyPromise {
        return AnyPromise(saveRecordToCloud(record: record))
    }

    public class func saveRecordToCloud(record: CKRecord) -> Promise<String> {
        return saveRecordToCloud(record: record,
                                 remainingRetries: maxRetries)
    }

    private class func saveRecordToCloud(record: CKRecord,
                                         remainingRetries: Int) -> Promise<String> {

        return Promise { resolver in
            let saveOperation = CKModifyRecordsOperation(recordsToSave: [record ], recordIDsToDelete: nil)
            saveOperation.modifyRecordsCompletionBlock = { (records, recordIds, error) in

                let outcome = outcomeForCloudKitError(error: error,
                                                      remainingRetries: remainingRetries,
                                                      label: "Save Record")
                switch outcome {
                case .success:
                    let recordName = record.recordID.recordName
                    resolver.fulfill(recordName)
                case .failureDoNotRetry(let outcomeError):
                    resolver.reject(outcomeError)
                case .failureRetryAfterDelay(let retryDelay):
                    DispatchQueue.global().asyncAfter(deadline: DispatchTime.now() + retryDelay, execute: {
                        saveRecordToCloud(record: record,
                                          remainingRetries: remainingRetries - 1)
                            .done { (recordName) in
                                resolver.fulfill(recordName)
                            }.catch { (error) in
                                resolver.reject(error)
                            }.retainUntilComplete()
                    })
                case .failureRetryWithoutDelay:
                    DispatchQueue.global().async {
                        saveRecordToCloud(record: record,
                                          remainingRetries: remainingRetries - 1)
                            .done { (recordName) in
                                resolver.fulfill(recordName)
                            }.catch { (error) in
                                resolver.reject(error)
                            }.retainUntilComplete()
                    }
                case .unknownItem:
                    owsFailDebug("unexpected CloudKit response.")
                    resolver.reject(invalidServiceResponseError())
                }
            }
            saveOperation.isAtomic = false

            // These APIs are only available in iOS 9.3 and later.
            if #available(iOS 9.3, *) {
                saveOperation.isLongLived = true
                saveOperation.qualityOfService = .background
            }

            database().add(saveOperation)
        }
    }

    // Compare:
    // * An "upsert" creates a new record if none exists and
    //   or updates if there is an existing record.
    // * A "save once" creates a new record if none exists and
    //   does nothing if there is an existing record.
    @objc
    public class func upsertFileToCloudObjc(fileUrl: URL,
                                            recordName: String,
                                            recordType: String) -> AnyPromise {
        return AnyPromise(upsertFileToCloud(fileUrl: fileUrl,
                                            recordName: recordName,
                                            recordType: recordType))
    }

    public class func upsertFileToCloud(fileUrl: URL,
                                        recordName: String,
                                        recordType: String) -> Promise<String> {

        return checkForFileInCloud(recordName: recordName,
                                   remainingRetries: maxRetries)
            .then { (record: CKRecord?) -> Promise<String> in
                if let record = record {
                    // Record found, updating existing record.
                    let asset = CKAsset(fileURL: fileUrl)
                    record[payloadKey] = asset
                    return saveRecordToCloud(record: record)
                }

                // No record found, saving new record.
                return saveFileToCloud(fileUrl: fileUrl,
                                       recordName: recordName,
                                       recordType: recordType)
        }
    }

    // Compare:
    // * An "upsert" creates a new record if none exists and
    //   or updates if there is an existing record.
    // * A "save once" creates a new record if none exists and
    //   does nothing if there is an existing record.
    @objc
    public class func saveFileOnceToCloudObjc(recordName: String,
                                              recordType: String,
                                              fileUrlBlock: @escaping () -> URL?) -> AnyPromise {
        return AnyPromise(saveFileOnceToCloud(recordName: recordName,
                                              recordType: recordType,
                                              fileUrlBlock: fileUrlBlock))
    }

    public class func saveFileOnceToCloud(recordName: String,
                                          recordType: String,
                                          fileUrlBlock: @escaping () -> URL?) -> Promise<String> {

        return checkForFileInCloud(recordName: recordName,
                                   remainingRetries: maxRetries)
            .then { (record: CKRecord?) -> Promise<String> in
                if record != nil {
                    // Record found, skipping save.
                    return Promise.value(recordName)
                }
                // No record found, saving new record.
                guard let fileUrl = fileUrlBlock() else {
                    Logger.error("error preparing file for upload.")
                    return Promise(error: OWSErrorWithCodeDescription(.exportBackupError,
                                                                      NSLocalizedString("BACKUP_EXPORT_ERROR_SAVE_FILE_TO_CLOUD_FAILED",
                                                                                        comment: "Error indicating the backup export failed to save a file to the cloud.")))
                }

                return saveFileToCloud(fileUrl: fileUrl,
                                       recordName: recordName,
                                       recordType: recordType)
        }
    }

    // MARK: - Delete

    @objc
    public class func deleteRecordsFromCloud(recordNames: [String],
                                             success: @escaping () -> Void,
                                             failure: @escaping (Error) -> Void) {
        deleteRecordsFromCloud(recordNames: recordNames,
                               remainingRetries: maxRetries,
                               success: success,
                               failure: failure)
    }

    private class func deleteRecordsFromCloud(recordNames: [String],
                                              remainingRetries: Int,
                                              success: @escaping () -> Void,
                                              failure: @escaping (Error) -> Void) {

        let recordIDs = recordNames.map { CKRecordID(recordName: $0) }
        let deleteOperation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: recordIDs)
        deleteOperation.modifyRecordsCompletionBlock = { (records, recordIds, error) in

            let outcome = outcomeForCloudKitError(error: error,
                                                  remainingRetries: remainingRetries,
                                                  label: "Delete Records")
            switch outcome {
            case .success:
                success()
            case .failureDoNotRetry(let outcomeError):
                failure(outcomeError)
            case .failureRetryAfterDelay(let retryDelay):
                DispatchQueue.global().asyncAfter(deadline: DispatchTime.now() + retryDelay, execute: {
                    deleteRecordsFromCloud(recordNames: recordNames,
                                           remainingRetries: remainingRetries - 1,
                                           success: success,
                                           failure: failure)
                })
            case .failureRetryWithoutDelay:
                DispatchQueue.global().async {
                    deleteRecordsFromCloud(recordNames: recordNames,
                                           remainingRetries: remainingRetries - 1,
                                           success: success,
                                           failure: failure)
                }
            case .unknownItem:
                owsFailDebug("unexpected CloudKit response.")
                failure(invalidServiceResponseError())
            }
        }
        database().add(deleteOperation)
    }

    // MARK: - Exists?

    private class func checkForFileInCloud(recordName: String,
                                           remainingRetries: Int) -> Promise<CKRecord?> {

        let (promise, resolver) = Promise<CKRecord?>.pending()

        let recordId = CKRecordID(recordName: recordName)
        let fetchOperation = CKFetchRecordsOperation(recordIDs: [recordId ])
        // Don't download the file; we're just using the fetch to check whether or
        // not this record already exists.
        fetchOperation.desiredKeys = []
        fetchOperation.perRecordCompletionBlock = { (record, recordId, error) in

            let outcome = outcomeForCloudKitError(error: error,
                                                  remainingRetries: remainingRetries,
                                                  label: "Check for Record")
            switch outcome {
            case .success:
                guard let record = record else {
                    owsFailDebug("missing fetching record.")
                    resolver.reject(invalidServiceResponseError())
                    return
                }
                // Record found.
                resolver.fulfill(record)
            case .failureDoNotRetry(let outcomeError):
                resolver.reject(outcomeError)
            case .failureRetryAfterDelay(let retryDelay):
                DispatchQueue.global().asyncAfter(deadline: DispatchTime.now() + retryDelay, execute: {
                    checkForFileInCloud(recordName: recordName,
                                        remainingRetries: remainingRetries - 1)
                        .done { (record) in
                            resolver.fulfill(record)
                        }.catch { (error) in
                            resolver.reject(error)
                        }.retainUntilComplete()
                })
            case .failureRetryWithoutDelay:
                DispatchQueue.global().async {
                    checkForFileInCloud(recordName: recordName,
                                        remainingRetries: remainingRetries - 1)
                        .done { (record) in
                            resolver.fulfill(record)
                        }.catch { (error) in
                            resolver.reject(error)
                        }.retainUntilComplete()
                }
            case .unknownItem:
                // Record not found.
                resolver.fulfill(nil)
            }
        }
        database().add(fetchOperation)
        return promise
    }

    @objc
    public class func checkForManifestInCloudObjc(recipientId: String) -> AnyPromise {
        return AnyPromise(checkForManifestInCloud(recipientId: recipientId))
    }

    public class func checkForManifestInCloud(recipientId: String) -> Promise<Bool> {

        let recordName = recordNameForManifest(recipientId: recipientId)
        return checkForFileInCloud(recordName: recordName,
                                   remainingRetries: maxRetries)
            .map { (record) in
                return record != nil
        }
    }

    @objc
    public class func allRecipientIdsWithManifestsInCloud(success: @escaping ([String]) -> Void,
                                                          failure: @escaping (Error) -> Void) {

        let processResults = { (recordNames: [String]) in
            DispatchQueue.global().async {
                let manifestRecordNames = recordNames.filter({ (recordName) -> Bool in
                    self.isManifest(recordName: recordName)
                })
                let recipientIds = self.recipientIds(forRecordNames: manifestRecordNames)
                success(recipientIds)
            }
        }

        let query = CKQuery(recordType: signalBackupRecordType, predicate: NSPredicate(value: true))
        // Fetch the first page of results for this query.
        fetchAllRecordNamesStep(recipientId: nil,
                                query: query,
                                previousRecordNames: [String](),
                                cursor: nil,
                                remainingRetries: maxRetries,
                                success: processResults,
                                failure: failure)
    }

    @objc
    public class func fetchAllRecordNames(recipientId: String,
                                          success: @escaping ([String]) -> Void,
                                          failure: @escaping (Error) -> Void) {

        let query = CKQuery(recordType: signalBackupRecordType, predicate: NSPredicate(value: true))
        // Fetch the first page of results for this query.
        fetchAllRecordNamesStep(recipientId: recipientId,
                                query: query,
                                previousRecordNames: [String](),
                                cursor: nil,
                                remainingRetries: maxRetries,
                                success: success,
                                failure: failure)
    }

    private class func fetchAllRecordNamesStep(recipientId: String?,
                                               query: CKQuery,
                                               previousRecordNames: [String],
                                               cursor: CKQueryCursor?,
                                               remainingRetries: Int,
                                               success: @escaping ([String]) -> Void,
                                               failure: @escaping (Error) -> Void) {

        var allRecordNames = previousRecordNames

        let queryOperation = CKQueryOperation(query: query)
        // If this isn't the first page of results for this query, resume
        // where we left off.
        queryOperation.cursor = cursor
        // Don't download the file; we're just using the query to get a list of record names.
        queryOperation.desiredKeys = []
        queryOperation.recordFetchedBlock = { (record) in
            assert(record.recordID.recordName.count > 0)

            let recordName = record.recordID.recordName

            if let recipientId = recipientId {
                let prefix = recordNamePrefix(forRecipientId: recipientId)
                guard recordName.hasPrefix(prefix) else {
                    Logger.info("Ignoring record: \(recordName)")
                    return
                }
            }

            allRecordNames.append(recordName)
        }
        queryOperation.queryCompletionBlock = { (cursor, error) in

            let outcome = outcomeForCloudKitError(error: error,
                                                  remainingRetries: remainingRetries,
                                                  label: "Fetch All Records")
            switch outcome {
            case .success:
                if let cursor = cursor {
                    Logger.verbose("fetching more record names \(allRecordNames.count).")
                    // There are more pages of results, continue fetching.
                    fetchAllRecordNamesStep(recipientId: recipientId,
                                            query: query,
                                            previousRecordNames: allRecordNames,
                                            cursor: cursor,
                                            remainingRetries: maxRetries,
                                            success: success,
                                            failure: failure)
                    return
                }
                Logger.info("fetched \(allRecordNames.count) record names.")
                success(allRecordNames)
            case .failureDoNotRetry(let outcomeError):
                failure(outcomeError)
            case .failureRetryAfterDelay(let retryDelay):
                DispatchQueue.global().asyncAfter(deadline: DispatchTime.now() + retryDelay, execute: {
                    fetchAllRecordNamesStep(recipientId: recipientId,
                                            query: query,
                                            previousRecordNames: allRecordNames,
                                            cursor: cursor,
                                            remainingRetries: remainingRetries - 1,
                                            success: success,
                                            failure: failure)
                })
            case .failureRetryWithoutDelay:
                DispatchQueue.global().async {
                    fetchAllRecordNamesStep(recipientId: recipientId,
                                            query: query,
                                            previousRecordNames: allRecordNames,
                                            cursor: cursor,
                                            remainingRetries: remainingRetries - 1,
                                            success: success,
                                            failure: failure)
                }
            case .unknownItem:
                owsFailDebug("unexpected CloudKit response.")
                failure(invalidServiceResponseError())
            }
        }
        database().add(queryOperation)
    }

    // MARK: - Download

    @objc
    public class func downloadManifestFromCloudObjc(recipientId: String) -> AnyPromise {
        return AnyPromise(downloadManifestFromCloud(recipientId: recipientId))
    }

    public class func downloadManifestFromCloud(recipientId: String) -> Promise<Data> {

        let recordName = recordNameForManifest(recipientId: recipientId)
        return downloadDataFromCloud(recordName: recordName)
    }

    @objc
    public class func downloadDataFromCloudObjc(recordName: String) -> AnyPromise {
        return AnyPromise(downloadDataFromCloud(recordName: recordName))
    }

    public class func downloadDataFromCloud(recordName: String) -> Promise<Data> {

        return downloadFromCloud(recordName: recordName,
                                 remainingRetries: maxRetries)
            .then { (asset) -> Promise<Data> in
                do {
                    let data = try Data(contentsOf: asset.fileURL)
                    return Promise.value(data)
                } catch {
                    Logger.error("couldn't load asset file: \(error).")
                    return Promise(error: invalidServiceResponseError())
                }
        }
    }

    @objc
    public class func downloadFileFromCloudObjc(recordName: String,
                                                toFileUrl: URL) -> AnyPromise {
        return AnyPromise(downloadFileFromCloud(recordName: recordName,
                                                toFileUrl: toFileUrl))
    }

    public class func downloadFileFromCloud(recordName: String,
                                            toFileUrl: URL) -> Promise<Void> {

        return downloadFromCloud(recordName: recordName,
                                 remainingRetries: maxRetries)
            .then { (asset) -> Promise<Void> in
                do {
                    try FileManager.default.copyItem(at: asset.fileURL, to: toFileUrl)
                    return Promise.value(())
                } catch {
                    Logger.error("couldn't copy asset file: \(error).")
                    return Promise(error: invalidServiceResponseError())
                }
        }
    }

    // We return the CKAsset and not its fileUrl because
    // CloudKit offers no guarantees around how long it'll
    // keep around the underlying file.  Presumably we can
    // defer cleanup by maintaining a strong reference to
    // the asset.
    private class func downloadFromCloud(recordName: String,
                                         remainingRetries: Int) -> Promise<CKAsset> {

        let (promise, resolver) = Promise<CKAsset>.pending()

        let recordId = CKRecordID(recordName: recordName)
        let fetchOperation = CKFetchRecordsOperation(recordIDs: [recordId ])
        // Download all keys for this record.
        fetchOperation.perRecordCompletionBlock = { (record, recordId, error) in

            let outcome = outcomeForCloudKitError(error: error,
                                                  remainingRetries: remainingRetries,
                                                  label: "Download Record")
            switch outcome {
            case .success:
                guard let record = record else {
                    Logger.error("missing fetching record.")
                    resolver.reject(invalidServiceResponseError())
                    return
                }
                guard let asset = record[payloadKey] as? CKAsset else {
                    Logger.error("record missing payload.")
                    resolver.reject(invalidServiceResponseError())
                    return
                }
                resolver.fulfill(asset)
            case .failureDoNotRetry(let outcomeError):
                resolver.reject(outcomeError)
            case .failureRetryAfterDelay(let retryDelay):
                DispatchQueue.global().asyncAfter(deadline: DispatchTime.now() + retryDelay, execute: {
                    downloadFromCloud(recordName: recordName,
                                      remainingRetries: remainingRetries - 1)
                        .done { (asset) in
                            resolver.fulfill(asset)
                        }.catch { (error) in
                            resolver.reject(error)
                        }.retainUntilComplete()
                })
            case .failureRetryWithoutDelay:
                DispatchQueue.global().async {
                    downloadFromCloud(recordName: recordName,
                                      remainingRetries: remainingRetries - 1)
                        .done { (asset) in
                            resolver.fulfill(asset)
                        }.catch { (error) in
                            resolver.reject(error)
                        }.retainUntilComplete()
                }
            case .unknownItem:
                Logger.error("missing fetching record.")
                resolver.reject(invalidServiceResponseError())
            }
        }
        database().add(fetchOperation)

        return promise
    }

    // MARK: - Access

    @objc public enum BackupError: Int, Error {
        case couldNotDetermineAccountStatus
        case noAccount
        case restrictedAccountStatus
    }

    @objc
    public class func ensureCloudKitAccessObjc() -> AnyPromise {
        return AnyPromise(ensureCloudKitAccess())
    }

    public class func ensureCloudKitAccess() -> Promise<Void> {
        let (promise, resolver) = Promise<Void>.pending()
        CKContainer.default().accountStatus { (accountStatus, error) in
            if let error = error {
                Logger.error("Unknown error: \(String(describing: error)).")
                resolver.reject(error)
                return
            }
            switch accountStatus {
            case .couldNotDetermine:
                Logger.error("could not determine CloudKit account status: \(String(describing: error)).")
                resolver.reject(BackupError.couldNotDetermineAccountStatus)
            case .noAccount:
                Logger.error("no CloudKit account.")
                resolver.reject(BackupError.noAccount)
            case .restricted:
                Logger.error("restricted CloudKit account.")
                resolver.reject(BackupError.restrictedAccountStatus)
            case .available:
                Logger.verbose("CloudKit access okay.")
                resolver.fulfill(())
            }
        }
        return promise
    }

    @objc
    public class func errorMessage(forCloudKitAccessError error: Error) -> String {
        if let backupError = error as? BackupError {
            Logger.error("Backup error: \(String(describing: backupError)).")
            switch backupError {
            case .couldNotDetermineAccountStatus:
                return NSLocalizedString("CLOUDKIT_STATUS_COULD_NOT_DETERMINE", comment: "Error indicating that the app could not determine that user's iCloud account status")
            case .noAccount:
                return NSLocalizedString("CLOUDKIT_STATUS_NO_ACCOUNT", comment: "Error indicating that user does not have an iCloud account.")
            case .restrictedAccountStatus:
                return NSLocalizedString("CLOUDKIT_STATUS_RESTRICTED", comment: "Error indicating that the app was prevented from accessing the user's iCloud account.")
            }
        } else {
            Logger.error("Unknown error: \(String(describing: error)).")
            return NSLocalizedString("CLOUDKIT_STATUS_COULD_NOT_DETERMINE", comment: "Error indicating that the app could not determine that user's iCloud account status")
        }
    }

    // MARK: - Retry

    private enum APIOutcome {
        case success
        case failureDoNotRetry(error:Error)
        case failureRetryAfterDelay(retryDelay: TimeInterval)
        case failureRetryWithoutDelay
        // This only applies to fetches.
        case unknownItem
    }

    private class func outcomeForCloudKitError(error: Error?,
                                               remainingRetries: Int,
                                               label: String) -> APIOutcome {
        if let error = error as? CKError {
            if error.code == CKError.unknownItem {
                // This is not always an error for our purposes.
                Logger.verbose("\(label) unknown item.")
                return .unknownItem
            }

            Logger.error("\(label) failed: \(error)")

            if remainingRetries < 1 {
                Logger.verbose("\(label) no more retries.")
                return .failureDoNotRetry(error:error)
            }

            if #available(iOS 11, *) {
                if error.code == CKError.serverResponseLost {
                    Logger.verbose("\(label) retry without delay.")
                    return .failureRetryWithoutDelay
                }
            }

            switch error {
            case CKError.requestRateLimited, CKError.serviceUnavailable, CKError.zoneBusy:
                let retryDelay = error.retryAfterSeconds ?? 3.0
                Logger.verbose("\(label) retry with delay: \(retryDelay).")
                return .failureRetryAfterDelay(retryDelay:retryDelay)
            case CKError.networkFailure:
                Logger.verbose("\(label) retry without delay.")
                return .failureRetryWithoutDelay
            default:
                Logger.verbose("\(label) unknown CKError.")
                return .failureDoNotRetry(error:error)
            }
        } else if let error = error {
            Logger.error("\(label) failed: \(error)")
            if remainingRetries < 1 {
                Logger.verbose("\(label) no more retries.")
                return .failureDoNotRetry(error:error)
            }
            Logger.verbose("\(label) unknown error.")
            return .failureDoNotRetry(error:error)
        } else {
            Logger.info("\(label) succeeded.")
            return .success
        }
    }

    // MARK: -

    @objc
    public class func setup() {
        cancelAllLongLivedOperations()
    }

    private class func cancelAllLongLivedOperations() {
        // These APIs are only available in iOS 9.3 and later.
        guard #available(iOS 9.3, *) else {
            return
        }

        let container = CKContainer.default()
        container.fetchAllLongLivedOperationIDs { (operationIds, error) in
            if let error = error {
                Logger.error("Could not get all long lived operations: \(error)")
                return
            }
            guard let operationIds = operationIds else {
                Logger.error("No operation ids.")
                return
            }

            for operationId in operationIds {
                container.fetchLongLivedOperation(withID: operationId, completionHandler: { (operation, error) in
                    if let error = error {
                        Logger.error("Could not get long lived operation [\(operationId)]: \(error)")
                        return
                    }
                    guard let operation = operation else {
                        Logger.error("No operation.")
                        return
                    }
                    operation.cancel()
                })
            }
        }
    }
}