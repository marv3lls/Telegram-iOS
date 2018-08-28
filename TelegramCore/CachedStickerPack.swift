import Foundation
#if os(macOS)
    import PostboxMac
    import SwiftSignalKitMac
#else
    import Postbox
    import SwiftSignalKit
#endif

final class CachedStickerPack: PostboxCoding {
    let info: StickerPackCollectionInfo?
    let items: [StickerPackItem]
    let hash: Int32
    
    init(info: StickerPackCollectionInfo?, items: [StickerPackItem], hash: Int32) {
        self.info = info
        self.items = items
        self.hash = hash
    }
    
    init(decoder: PostboxDecoder) {
        self.info = decoder.decodeObjectForKey("in", decoder: { StickerPackCollectionInfo(decoder: $0) }) as? StickerPackCollectionInfo
        self.items = decoder.decodeObjectArrayForKey("it").map { $0 as! StickerPackItem }
        self.hash = decoder.decodeInt32ForKey("h", orElse: 0)
    }
    
    func encode(_ encoder: PostboxEncoder) {
        if let info = self.info {
            encoder.encodeObject(info, forKey: "in")
        } else {
            encoder.encodeNil(forKey: "in")
        }
        encoder.encodeObjectArray(self.items, forKey: "it")
        encoder.encodeInt32(self.hash, forKey: "h")
    }
    
    static func cacheKey(_ id: ItemCollectionId) -> ValueBoxKey {
        let key = ValueBoxKey(length: 4 + 8)
        key.setInt32(0, value: id.namespace)
        key.setInt64(4, value: id.id)
        return key
    }
}

private let collectionSpec = ItemCacheCollectionSpec(lowWaterItemCount: 100, highWaterItemCount: 200)

public enum CachedStickerPackResult {
    case none
    case fetching
    case result(StickerPackCollectionInfo, [ItemCollectionItem], Bool)
}

func cacheStickerPack(transaction: Transaction, info: StickerPackCollectionInfo, items: [ItemCollectionItem]) {
    transaction.putItemCacheEntry(id: ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.cachedStickerPacks, key: CachedStickerPack.cacheKey(info.id)), entry: CachedStickerPack(info: info, items: items.map { $0 as! StickerPackItem }, hash: info.hash), collectionSpec: collectionSpec)
}

public func cachedStickerPack(postbox: Postbox, network: Network, reference: StickerPackReference) -> Signal<CachedStickerPackResult, NoError> {
    return postbox.transaction { transaction -> Signal<CachedStickerPackResult, NoError> in
        let namespace = Namespaces.ItemCollection.CloudStickerPacks
        if case let .id(id, _) = reference, let currentInfo = transaction.getItemCollectionInfo(collectionId: ItemCollectionId(namespace: namespace, id: id)) as? StickerPackCollectionInfo {
            let items = transaction.getItemCollectionItems(collectionId: ItemCollectionId(namespace: namespace, id: id))
            return .single(.result(currentInfo, items, true))
        } else {
            let current: Signal<CachedStickerPackResult, NoError>
            var loadRemote = false
            
            if case let .id(id, _) = reference, let cached = transaction.retrieveItemCacheEntry(id: ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.cachedStickerPacks, key: CachedStickerPack.cacheKey(ItemCollectionId(namespace: namespace, id: id)))) as? CachedStickerPack, let info = cached.info {
                current = .single(.result(info, cached.items, false))
                if cached.hash != info.hash {
                    loadRemote = true
                }
            } else {
                current = .single(.fetching)
                loadRemote = true
            }
            
            var signal = current
            if loadRemote {
                let appliedRemote = updatedRemoteStickerPack(postbox: postbox, network: network, reference: reference)
                |> mapToSignal { result -> Signal<CachedStickerPackResult, NoError> in
                    return postbox.transaction { transaction -> CachedStickerPackResult in
                        if let result = result {
                            cacheStickerPack(transaction: transaction, info: result.0, items: result.1)
                            
                            let currentInfo = transaction.getItemCollectionInfo(collectionId: result.0.id) as? StickerPackCollectionInfo
                            
                            return .result(result.0, result.1, currentInfo != nil)
                        } else {
                            return .none
                        }
                    }
                }
                
                signal = signal
                |> then(appliedRemote)
            }
            
            return signal
        }
    }
    |> switchToLatest
}
