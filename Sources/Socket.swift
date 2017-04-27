//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation


#if os(Linux)
import Glibc
#else
import Darwin
#endif


public class Socket : Selectable {
    private let fd: Int32;
    public internal(set) var open: Bool;
    
    init() throws {
#if os(Linux)
        self.fd = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
#else
        self.fd = Darwin.socket(AF_INET, Int32(SOCK_STREAM), 0)
#endif
        if self.fd < 0 {
            throw IOError(errno: errno, reason: "socket(...) failed")
        }
        self.open = true
    }
    
    init(fd : Int32) {
        self.fd = fd
        self.open = true
    }
    
    public func localAddress() -> SocketAddress? {
        return nil
    }
    
    public func remoteAddress() -> SocketAddress? {
        return nil;
    }
    
    public func descriptor() -> Int32 {
        return fd
    }
    
    public func setNonBlocking() throws {
        let res = fcntl(self.fd, F_SETFL, O_NONBLOCK)
        
        guard res >= 0 else {
            throw IOError(errno: errno, reason: "fcntl(...) failed")
        }
        
    }
    
    public func close() throws {
#if os(Linux)
        let res = Glibc.close(self.fd)
#else
        let res = Darwin.close(self.fd)
#endif
        guard res >= 0 else {
            throw IOError(errno: errno, reason: "shutdown(...) failed")
        }
    }
    
    public func write(data: Data, offset: Int, len: Int) throws -> Int {
        let res = data.withUnsafeBytes() { [unowned self] (buffer: UnsafePointer<UInt8>) -> Int in
        #if os(Linux)
            return Glibc.write(self.fd, buffer.advanced(by: offset), len)
        #else
            return Darwin.Glibc.write(self.fd, buffer.advanced(by: offset), len)
        #endif
        }

        guard res >= 0 else {
            let err = errno
            guard err == EWOULDBLOCK else {
                throw IOError(errno: errno, reason: "write(...) failed")
            }
            return -1
        }
        return res
    }
    
    public func read(data: inout Data, offset: Int, len: Int) throws -> Int {
        let res = data.withUnsafeMutableBytes() { [unowned self] (buffer: UnsafeMutablePointer<UInt8>) -> Int in
            #if os(Linux)
                return Glibc.read(self.fd, buffer.advanced(by: offset), len)
            #else
                return Darwin.read(self.fd, buffer.advanced(by: offset), len)
            #endif
        }

        guard res >= 0 else {
            let err = errno
            guard err == EWOULDBLOCK else {
                throw IOError(errno: errno, reason: "read(...) failed")
            }
            return -1
        }
        return res
    }
}