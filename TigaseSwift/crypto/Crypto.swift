//
// Crypto.swift
//
// TigaseSwift
// Copyright (C) 2016 "Tigase, Inc." <office@tigase.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License,
// or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. Look for COPYING file in the top folder.
// If not, see http://www.gnu.org/licenses/.
//

import Foundation
import CommonCrypto

protocol DigestProtocol {
    func digest(_ bytes: UnsafeRawPointer, length: Int) -> [UInt8];
}

/**
 This enum is in fact a wrapper/helper for hashing functions from `CommonCrypto` library.
 For now it supports following hashing functions:
 - md5
 - sha1
 - sha256
 */
public enum Digest: DigestProtocol {
    
    case md5
    case sha1
    case sha256
    
    /**
     Function processes bytes from unsafe buffer and calculates hash
     - parameter bytes: bytes to process
     - parameter length: number of bytes to process
     - returns: hash in form of array of bytes
     */
    public func digest(_ bytes: UnsafeRawPointer, length inLength: Int) -> [UInt8] {
        let length = UInt32(inLength);
        switch self {
        case .md5:
            var hash = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH));
            CC_MD5(bytes, length, &hash);
            return hash;
        case .sha1:
            var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH));
            CC_SHA1(bytes, length, &hash);
            return hash;
        case .sha256:
            var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH));
            CC_SHA256(bytes, length, &hash);
            return hash;
        }
    }
    
    /**
     Convenience function to calculate hash of data provided in NSData
     - parameter data: data to process
     - returns: hash in form of array of bytes
     */
    public func digest(_ data: Data?) -> [UInt8]? {
        guard data != nil else {
            return nil;
        }
        return self.digest((data! as NSData).bytes, length: data!.count);
    }
    
    /**
     Convenience function to calculate hash of data provided in NSData
     and return it as NSData
     - parameter data: data to process
     - returns: hash as NSData
     */
    public func digest(_ data: Data?) -> Data? {
        if var hash:[UInt8] = self.digest(data) {
            return Data(bytes: &hash, count: hash.count);
        }
        return nil;
    }
    
    /**
     Convenience function to calculate hash of data provided in NSData
     which returns Base64 encoded representation of hash value
     - parameter data: data to process
     - returns: Base64 encoded representation of hash
     */
    public func digestToBase64(_ data: Data?) -> String? {
        let result:Data? = digest(data);
        return result?.base64EncodedString(options: NSData.Base64EncodingOptions(rawValue: 0));
    }
    
    /**
     Convenience function to calculate hash of data provided in NSData
     which returns hex encoded representation of hash value
     - parameter data: data to process
     - returns: hex encoded hash value
     */
    public func digestToHex(_ data: Data?) -> String? {
        if let result:[UInt8] = digest(data) {
            return result.map() { String(format: "%02x", $0) }.reduce("", +);
        }
        return nil;
    }
    
    public func hmac(_ keyBytes: UnsafeRawPointer, keyLength: Int, bytes: UnsafeRawPointer, length: Int) -> [UInt8] {
        let ctx = UnsafeMutablePointer<CCHmacContext>.allocate(capacity: 1);
        var algorithm: Int;
        var hmacLength: Int;
        switch (self) {
        case .md5:
            algorithm = kCCHmacAlgMD5;
            hmacLength = Int(CC_MD5_DIGEST_LENGTH);
        case .sha1:
            algorithm = kCCHmacAlgSHA1;
            hmacLength = Int(CC_SHA1_DIGEST_LENGTH);
        case .sha256:
            algorithm = kCCHmacAlgSHA256;
            hmacLength = Int(CC_SHA256_DIGEST_LENGTH);
        }
        CCHmacInit(ctx, CCHmacAlgorithm(algorithm), keyBytes, keyLength);
        CCHmacUpdate(ctx, bytes, length);
        
        var digest = Array<UInt8>(repeating: 0, count: hmacLength);
        CCHmacFinal(ctx, &digest);
        
        return digest;
    }
    
    public func hmac(_ key: inout [UInt8], data: inout [UInt8]) -> [UInt8] {
        return hmac(Digest.convert(&key), keyLength: key.count, bytes: &data, length: data.count);
    }

    public func hmac(_ keyData: Data, data: inout [UInt8]) -> [UInt8] {
        return hmac((keyData as NSData).bytes, keyLength: keyData.count, bytes: &data, length: data.count);
    }
    
    public func hmac(_ key: inout [UInt8], data: Data) -> [UInt8] {
        return hmac(Digest.convert(&key), keyLength: key.count, bytes: (data as NSData).bytes, length: data.count);
    }
    
    fileprivate static func convert(_ ptr: UnsafePointer<UInt8>) -> UnsafeRawPointer {
        return UnsafeRawPointer(ptr);
    }
}
