//
//  PrivateDatabaseManager.swift
//  IceCream
//
//  Created by caiyue on 2019/4/22.
//

#if os(macOS)
import Cocoa
#else
import UIKit
#endif

import CloudKit
import Combine

final class PrivateDatabaseManager: DatabaseManager {
    
    let container: CKContainer
    let database: CKDatabase
    
    let syncObjects: [Syncable]
    
    private var fetchNotificationCancellable: AnyCancellable?
    
    public init(objects: [Syncable], container: CKContainer) {
        self.syncObjects = objects
        self.container = container
        self.database = container.privateCloudDatabase
    }
    
    func fetchChangesInDatabase(_ callback: ((Error?) -> Void)?) {
        let changesOperation = CKFetchDatabaseChangesOperation(previousServerChangeToken: databaseChangeToken)
        
        /// Only update the changeToken when fetch process completes
        changesOperation.changeTokenUpdatedBlock = { [weak self] newToken in
            self?.databaseChangeToken = newToken
        }
        
        changesOperation.fetchDatabaseChangesCompletionBlock = {
            [weak self]
            newToken, _, error in
            guard let self = self else { return }
            switch ErrorHandler.shared.resultType(with: error) {
            case .success:
                self.databaseChangeToken = newToken
                // Fetch the changes in zone level
                self.fetchChangesInZones(callback)
            case .retry(let timeToWait, _):
                ErrorHandler.shared.retryOperationIfPossible(retryAfter: timeToWait, block: {
                    self.fetchChangesInDatabase(callback)
                })
            case .recoverableError(let reason, _):
                switch reason {
                case .changeTokenExpired:
                    /// The previousServerChangeToken value is too old and the client must re-sync from scratch
                    self.databaseChangeToken = nil
                    self.fetchChangesInDatabase(callback)
                default:
                    callback?(error)
                }
            default:
                callback?(error)
                return
            }
        }
        
        // upping service quality will trigger better error reporting e.g. internet disconnected will return error instead of just hanging...
        changesOperation.qualityOfService = .userInitiated
        database.add(changesOperation)
    }
    
    func createCustomZonesIfAllowed() {
        let zonesToCreate = syncObjects.filter { !$0.isCustomZoneCreated }.map { CKRecordZone(zoneID: $0.zoneID) }
        guard zonesToCreate.count > 0 else { return }
        
        let modifyOp = CKModifyRecordZonesOperation(recordZonesToSave: zonesToCreate, recordZoneIDsToDelete: nil)
        modifyOp.modifyRecordZonesCompletionBlock = { [weak self](_, _, error) in
            guard let self = self else { return }
            switch ErrorHandler.shared.resultType(with: error) {
            case .success:
                self.syncObjects.forEach { object in
                    object.isCustomZoneCreated = true
                    
                    // As we register local database in the first step, we have to force push local objects which
                    // have not been caught to CloudKit to make data in sync
                    DispatchQueue.main.async {
                        object.pushLocalObjectsToCloudKit(completion: nil)
                    }
                }
            case .retry(let timeToWait, _):
                ErrorHandler.shared.retryOperationIfPossible(retryAfter: timeToWait, block: {
                    self.createCustomZonesIfAllowed()
                })
            default:
                return
            }
        }
        
        database.add(modifyOp)
    }
    
    func createDatabaseSubscriptionIfHaveNot() {
        #if os(iOS) || os(tvOS) || os(macOS)
        guard !subscriptionIsLocallyCached else { return }
        let subscription = CKDatabaseSubscription(subscriptionID: IceCreamSubscription.cloudKitPrivateDatabaseSubscriptionID.id)
        
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true // Silent Push
        
        subscription.notificationInfo = notificationInfo
        
        let createOp = CKModifySubscriptionsOperation(subscriptionsToSave: [subscription], subscriptionIDsToDelete: [])
        createOp.modifySubscriptionsCompletionBlock = { _, _, error in
            guard error == nil else { return }
            self.subscriptionIsLocallyCached = true
        }
        createOp.qualityOfService = .utility
        database.add(createOp)
        #endif
    }
    
    func startObservingTermination() {
        #if os(iOS) || os(tvOS)
        
        NotificationCenter.default.addObserver(self, selector: #selector(self.cleanUp), name: UIApplication.willTerminateNotification, object: nil)
        
        #elseif os(macOS)
        
        NotificationCenter.default.addObserver(self, selector: #selector(self.cleanUp), name: NSApplication.willTerminateNotification, object: nil)
        
        #endif
    }
    
    func registerLocalDatabase() {
        self.syncObjects.forEach { object in
            DispatchQueue.main.async {
                object.registerLocalDatabase()
            }
        }
    }
    
    private func fetchChangesInZones(_ callback: ((Error?) -> Void)? = nil) {
        let changesOp = CKFetchRecordZoneChangesOperation(recordZoneIDs: zoneIds, optionsByRecordZoneID: zoneIdOptions)
        changesOp.fetchAllChanges = true
        
        // if we retry fetch after getting a recoverable error
        var isRetrying = false

        print("^^ fetchChangesInZones started for operation : \(changesOp)")

        changesOp.recordZoneChangeTokensUpdatedBlock = { [weak self] zoneId, token, _ in
            guard let self = self else { return }
            guard let syncObject = self.syncObjects.first(where: { $0.zoneID == zoneId }) else { return }
            syncObject.zoneChangesToken = token
        }
        if #available(iOS 15, *) {
            changesOp.recordWasChangedBlock = { [weak self] recordID, recordResult in
                guard let self = self else { return }
                switch recordResult {
                case .failure(let error):
                    print("^^ error processing record id \(recordID), error : \(error)")
                case .success(let record):
                    /// CloudKit will return the modified record since the last zoneChangesToken, we need to do local cache here.
                    guard let syncObject = self.syncObjects.first(where: { $0.recordType == record.recordType }) else { return }
                    print("^^ fetchChangesInZones add record : \(record) in operation : \(changesOp)")
                    syncObject.add(record: record)
                }
            }
        } else {
            // deprecated as of ios 15
            changesOp.recordChangedBlock = { [weak self] record in
                /// The Cloud will return the modified record since the last zoneChangesToken, we need to do local cache here.
                /// Handle the record:
                guard let self = self else { return }
                guard let syncObject = self.syncObjects.first(where: { $0.recordType == record.recordType }) else { return }
                syncObject.add(record: record)
            }
        }
        
        changesOp.recordWithIDWasDeletedBlock = { [weak self] recordId, _ in
            guard let self = self else { return }
            guard let syncObject = self.syncObjects.first(where: { $0.zoneID == recordId.zoneID }) else { return }
            print("^^ fetchChangesInZones delete record : \(recordId) in operation : \(changesOp)")
            syncObject.delete(recordID: recordId)
        }
        
        changesOp.recordZoneFetchCompletionBlock = { [weak self](zoneId ,token, _, _, error) in
            guard let self = self else { return }


            switch ErrorHandler.shared.resultType(with: error) {
            case .success:
                guard let syncObject = self.syncObjects.first(where: { $0.zoneID == zoneId }) else { return }
                print("^^ recordZoneFetchCompletionBlock in operation : \(changesOp), token : \(String(describing: token))")
                
                syncObject.zoneChangesToken = token
            case .retry(let timeToWait, _):
                ErrorHandler.shared.retryOperationIfPossible(retryAfter: timeToWait, block: {
                    isRetrying = true
                    self.fetchChangesInZones(callback)
                })
            case .recoverableError(let reason, _):
                switch reason {
                case .changeTokenExpired:
                    print("The previousServerChangeToken value is too old for zone id : \(zoneId) and the client must re-sync from scratch")
                    guard let syncObject = self.syncObjects.first(where: { $0.zoneID == zoneId }) else { return }
                    syncObject.zoneChangesToken = nil
                    isRetrying = true
                    self.fetchChangesInZones(callback)
                default:
                    // could not recover, fetchRecordZoneChangesCompletionBlock will send back error
                    return
                }
            default:
                // could not retry/recover, fetchRecordZoneChangesCompletionBlock will send back error
                return
            }
        }
        
        changesOp.fetchRecordZoneChangesCompletionBlock = { [weak self] error in
            guard let self = self else { return }
            self.syncObjects.forEach {
                $0.resolvePendingRelationships()
            }
            
            print("^^ fetchRecordZoneChangesCompletionBlock for operation : \(changesOp) error : \(String(describing: error))")
            if isRetrying {
                print("^^ is retrying fetch")
                isRetrying = false
            } else {
                callback?(error)
            }
        }
                
        database.add(changesOp)
    }
}

extension PrivateDatabaseManager {
    /// The changes token, for more please reference to https://developer.apple.com/videos/play/wwdc2016/231/
    var databaseChangeToken: CKServerChangeToken? {
        get {
            /// For the very first time when launching, the token will be nil and the server will be giving everything on the Cloud to client
            /// In other situation just get the unarchive the data object
            guard let tokenData = UserDefaults.standard.object(forKey: IceCreamKey.databaseChangesTokenKey.value) as? Data else { return nil }
            return NSKeyedUnarchiver.unarchiveObject(with: tokenData) as? CKServerChangeToken
        }
        set {
            guard let n = newValue else {
                UserDefaults.standard.removeObject(forKey: IceCreamKey.databaseChangesTokenKey.value)
                return
            }
            let data = NSKeyedArchiver.archivedData(withRootObject: n)
            UserDefaults.standard.set(data, forKey: IceCreamKey.databaseChangesTokenKey.value)
        }
    }
    
    var subscriptionIsLocallyCached: Bool {
        get {
            guard let flag = UserDefaults.standard.object(forKey: IceCreamKey.subscriptionIsLocallyCachedKey.value) as? Bool  else { return false }
            return flag
        }
        set {
            UserDefaults.standard.set(newValue, forKey: IceCreamKey.subscriptionIsLocallyCachedKey.value)
        }
    }
    
    private var zoneIds: [CKRecordZone.ID] {
        return syncObjects.map { $0.zoneID }
    }
    
    private var zoneIdOptions: [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneOptions] {
        return syncObjects.reduce([CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneOptions]()) { (dict, syncObject) -> [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneOptions] in
            var dict = dict
            let zoneChangesOptions = CKFetchRecordZoneChangesOperation.ZoneOptions()
            zoneChangesOptions.previousServerChangeToken = syncObject.zoneChangesToken
            dict[syncObject.zoneID] = zoneChangesOptions
            return dict
        }
    }
    
    @objc func cleanUp() {
        for syncObject in syncObjects {
            syncObject.cleanUp()
        }
    }
}

extension PrivateDatabaseManager {

    ///
    /// Will listen for cloudkit notifications and refresh the database with the latest changes.
    /// Override default impl to throttle so many successive refreshes are not queued up unnecessarily. 
    ///
    func startObservingRemoteChanges() {

        fetchNotificationCancellable = NotificationCenter.default
            .publisher(for: Notifications.cloudKitDataDidChangeRemotely.name)
            .throttle(for: 2.0, scheduler: DispatchQueue.global(qos: .utility), latest: true)
            .sink() { [weak self] _ in
                self?.fetchChangesInDatabase(nil)
            }

    }

}
