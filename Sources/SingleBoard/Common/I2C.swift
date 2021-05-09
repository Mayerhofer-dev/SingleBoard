/*
 SingleBoard - Common

 Copyright (c) 2018 Adam Thayer
 SwiftyGPIO I2C Implementation Copyright (c) 2017 Umberto Raimondi

 Licensed under the MIT license, as follows:

 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 SOFTWARE.)
 */

#if os(Linux)
    import Glibc
#else
    import Darwin.C
#endif

import Foundation

public enum I2CError: Error {
    case failed
}

public extension BoardI2CEndpoint {
    // Convenience for RawRepresentable SMBus Commands
    func readByte<T: RawRepresentable>(command: T) throws -> UInt8
        where T.RawValue == UInt8
    {
        return try self.readByte(command: command.rawValue)
    }
    
    func readWord<T: RawRepresentable>(command: T) throws -> UInt16
        where T.RawValue == UInt8
    {
        return try self.readWord(command: command.rawValue)
    }
    
    func writeByte<T: RawRepresentable>(command: T, value: UInt8) throws
        where T.RawValue == UInt8
    {
        return try self.writeByte(command: command.rawValue, value: value)
    }
    
    func writeWord<T: RawRepresentable>(command: T, value: UInt16) throws
        where T.RawValue == UInt8
    {
        return try self.writeWord(command: command.rawValue, value: value)
    }
    
    // Read in Enums and OptionSets
    func read<T: RawRepresentable>() throws -> T?
        where T.RawValue == UInt8
    {
        return T(rawValue: try self.readByte())
    }

    func read<T: RawRepresentable>() throws -> T?
        where T.RawValue == UInt16
    {
        return T(rawValue: try self.readWord())
    }

    func read<T: RawRepresentable, U: RawRepresentable>(command: T) throws -> U?
        where T.RawValue == UInt8, U.RawValue == UInt8
    {
        return U(rawValue: try self.readByte(command: command.rawValue))
    }

    func read<T: RawRepresentable, U: RawRepresentable>(command: T) throws -> U?
        where T.RawValue == UInt8, U.RawValue == UInt16
    {
        return U(rawValue: try self.readWord(command: command.rawValue))
    }

    func read<T: RawRepresentable, U: OptionSet>(command: T) throws -> U
        where T.RawValue == UInt8, U.RawValue == UInt8
    {
        return U(rawValue: try self.readByte(command: command.rawValue))
    }

    func read<T: RawRepresentable, U: OptionSet>(command: T) throws -> U
        where T.RawValue == UInt8, U.RawValue == UInt16
    {
        return U(rawValue: try self.readWord(command: command.rawValue))
    }

    // Write Enums and OptionSets
    func write<T: RawRepresentable>(value: T) throws
        where T.RawValue == UInt8
    {
        return try self.writeByte(value: value.rawValue)
    }

    func write<T: RawRepresentable>(value: T) throws
        where T.RawValue == UInt16
    {
        return try self.writeWord(value: value.rawValue)
    }

    func write<T: RawRepresentable, U: RawRepresentable>(command: T, value: U) throws
        where T.RawValue == UInt8, U.RawValue == UInt8
    {
        return try self.writeByte(command: command.rawValue, value: value.rawValue)
    }

    func write<T: RawRepresentable, U: RawRepresentable>(command: T, value: U) throws
        where T.RawValue == UInt8, U.RawValue == UInt16
    {
        return try self.writeWord(command: command.rawValue, value: value.rawValue)
    }
}

// This would normally be easier in Swift 4:
// extension Dictionary: BoardI2C where Key == Int, Value == BoardI2CChannel {}
class SysI2CBoard: BoardI2CBusSet {
    let mainBus: BoardI2CBus
    private let buses: [Int: BoardI2CBus]

    init(range: CountableClosedRange<Int>, mainBus: BoardI2CBus) {
        var buses: [Int: BoardI2CBus] = [:]
        for index in range {
            if mainBus.busId == index {
                buses[index] = mainBus
            } else {
                buses[index] = SysI2CBus(busIndex: index)
            }
        }

        self.buses = buses
        self.mainBus = mainBus
    }

    init(buses: [Int: BoardI2CBus], mainBus: BoardI2CBus) {
        self.buses = buses
        self.mainBus = mainBus
    }

    subscript(busIndex: Int) -> BoardI2CBus? {
        return buses[busIndex]
    }
}

public final class SysI2CBus: BoardI2CBus {
    private static let I2C_SLAVE: UInt = 0x703
    private static let I2C_SLAVE_FORCE: UInt = 0x706
    private static let I2C_RDWR: UInt = 0x707
    private static let I2C_PEC: UInt = 0x708
    private static let I2C_SMBUS: UInt = 0x720
    private static let I2C_MAX_LENGTH: Int = 32

    public let busId: Int
    private var fdI2C: Int32 = -1
    private var currentEndpoint: UInt8?
    private var activeEndpoints: [UInt8: BoardI2CEndpoint] = [:]

    public init(busIndex: Int) {
        self.busId = busIndex
    }

    deinit {
        if fdI2C != -1 {
            close(fdI2C)
        }
    }

    public func isReachable(address: UInt8) -> Bool {
        return self[address].reachable
    }

    public subscript(address: UInt8) -> BoardI2CEndpoint {
        if let endpoint = self.activeEndpoints[address] {
            return endpoint
        }

        let endpoint = SysI2CEndpoint(address: address, controller: self)
        self.activeEndpoints[address] = endpoint
        return endpoint
    }

    fileprivate func openChannel() throws {
        let filePath: String = "/dev/i2c-\(self.busId)"

        let fdI2C = open(filePath, O_RDWR)
        guard fdI2C > 0 else {
            throw I2CError.failed
        }

        self.fdI2C = fdI2C
    }

    // MARK: I2C Read/Write
    fileprivate func readByte(at address: UInt8) throws -> UInt8? {
        var data = [UInt8](repeating: 0, count: 1)
        guard try i2cIoctl(.read, address: address, length: UInt16(data.count), data: &data) else { return nil }
        return data[0]
    }

    fileprivate func readWord(at address: UInt8) throws -> UInt16? {
        var data = [UInt8](repeating: 0, count: 2)
        guard try i2cIoctl(.read, address: address, length: UInt16(data.count), data: &data) else { return nil }
        return (UInt16(data[1]) << 8) + UInt16(data[0])
    }

    fileprivate func readData(at address: UInt8, length: Int) throws -> Data? {
        var data = Data(count: length)
        let success = try data.withUnsafeMutableBytes {
            (dataBuffer) in
            return try i2cIoctl(.read, address: address, length: UInt16(length), data: dataBuffer)
        }
        return success ? data : nil
    }

    fileprivate func writeByte(at address: UInt8, value: UInt8) throws -> Bool {
        var data = [UInt8](repeating:0, count: 1)

        data[0] = value
        return try i2cIoctl(.write, address: address, length: 1, data: &data)
    }

    fileprivate func writeWord(at address: UInt8, value: UInt16) throws -> Bool {
        var data = [UInt8](repeating:0, count: 2)

        data[0] = UInt8(value & 0xFF)
        data[1] = UInt8(value >> 8)
        return try i2cIoctl(.write, address: address, length: 2, data: &data)
    }

    fileprivate func writeData(at address: UInt8, value: Data) throws -> Bool {
        var internalValue = value
        return try internalValue.withUnsafeMutableBytes {
            (dataBuffer) in
            return try i2cIoctl(.write, address: address, length: UInt16(value.count), data: dataBuffer)
        }
    }

    private func i2cIoctl(_ readOrWrite: SMBusReadWrite, address: UInt8, length: UInt16, data: UnsafeMutablePointer<UInt8>?) throws -> Bool {
        if self.fdI2C == -1 {
            try self.openChannel()
        }

        let flags: I2CMessageFlags = readOrWrite.isRead ? [.read] : []

        var message = I2CMessage(UInt16(address), flags: flags, length: length, data: data)
        var messageSet = I2CMessageSet(&message, count: 1)
        guard ioctl(fdI2C, SysI2CBus.I2C_RDWR, &messageSet) >= 0 else {
            print("I2C_RDWR Error: \(errno)")
            return false
        }
        return true
    }

    // MARK: SMBus Read/Write
    fileprivate func setCurrentEndpoint(to address: UInt8) throws {
        if self.fdI2C == -1 {
            try self.openChannel()
        }

        guard self.currentEndpoint != address else { return }

        let result = ioctl(fdI2C, SysI2CBus.I2C_SLAVE_FORCE, CInt(address))
        guard result == 0 else {
            throw I2CError.failed
        }

        self.currentEndpoint = address
    }

    fileprivate func readByte(command: UInt8) throws -> UInt8? {
        var data = [UInt8](repeating:0, count: SysI2CBus.I2C_MAX_LENGTH+1)

        guard try smbusIoctl(.read, command: command, dataKind: .byteData, data: &data) else { return nil }
        return data[0]
    }

    fileprivate func readWord(command: UInt8) throws -> UInt16? {
        var data = [UInt8](repeating:0, count: SysI2CBus.I2C_MAX_LENGTH+1)

        guard try smbusIoctl(.read, command: command, dataKind: .wordData, data: &data) else { return nil }
        return (UInt16(data[1]) << 8) + UInt16(data[0])
    }

    fileprivate func readData(command: UInt8) throws -> Data? {
        var data = Data(count: SysI2CBus.I2C_MAX_LENGTH+1)
        let success = try data.withUnsafeMutableBytes {
            (dataBuffer) in
            return try smbusIoctl(.read, command: command, dataKind: .blockData, data: dataBuffer)
        }
        guard success else { return nil }
        guard let length = data.popFirst() else { return nil }
        data.removeSubrange(Int(length)...data.count)
        return data
    }

    fileprivate func readByteArray(command: UInt8) throws -> [UInt8]? {
        var data = [UInt8](repeating:0, count: SysI2CBus.I2C_MAX_LENGTH+1)

        guard try smbusIoctl(.read, command: command, dataKind: .blockData, data: &data) else { return nil }
        let lenData = Int(data[0])
        return Array(data[1...lenData])
    }

    fileprivate func writeQuick() throws -> Bool {
        return try smbusIoctl(.write, command: 0, dataKind: .quick, data: nil)
    }

    fileprivate func writeByte(command: UInt8, value: UInt8) throws -> Bool {
        var data = Data(count: MemoryLayout<UInt8>.size)
        data[0] = value

        return try data.withUnsafeMutableBytes {
            (dataBuffer) in
            return try smbusIoctl(.write, command: command, dataKind: .byteData, data: dataBuffer)
        }
    }

    fileprivate func writeWord(command: UInt8, value: UInt16) throws -> Bool {
        var data = Data(count: MemoryLayout<UInt16>.size)
        data[0] = UInt8(value & 0xFF)
        data[1] = UInt8(value >> 8)

        return try data.withUnsafeMutableBytes {
            (dataBuffer) in
            return try smbusIoctl(.write, command: command, dataKind: .wordData, data: dataBuffer)
        }
    }

    fileprivate func writeData(command: UInt8, value: Data) throws -> Bool {
        guard value.count <= SysI2CBus.I2C_MAX_LENGTH else { return false }
        var data = Data(capacity: value.count + 1)
        data.append(UInt8(value.count))
        data.append(data)
        return try data.withUnsafeMutableBytes {
            (dataBuffer) in
            return try smbusIoctl(.write, command: command, dataKind: .blockData, data: dataBuffer)
        }
    }

    private func smbusIoctl(_ readOrWrite: SMBusReadWrite, command: UInt8, dataKind: SMBusDataKind, data: UnsafeMutablePointer<UInt8>?) throws -> Bool {
        if self.fdI2C == -1 {
            try self.openChannel()
        }

        var args = SMBusData(readOrWrite, command: command, dataKind: dataKind, data: data)
        guard ioctl(self.fdI2C, SysI2CBus.I2C_SMBUS, &args) >= 0 else { 
            print("I2C_SMBUS Error: \(errno)")
            return false
                }
        return true
    }
}

public final class SysI2CEndpoint: BoardI2CEndpoint {
    private let address: UInt8
    private let controller: SysI2CBus

    init(address: UInt8, controller: SysI2CBus) {
        self.address = address
        self.controller = controller
    }

    public var reachable: Bool {
        do {
            try controller.setCurrentEndpoint(to: address)
            return (try? controller.readByte(command: 0)) != nil
        } catch {
            return false
        }
    }

    //
    // Generic I2C
    //

    public func readByte() throws -> UInt8 {
        guard let byte = try controller.readByte(at: address) else { throw I2CError.failed }
        return byte
    }

    public func readWord() throws -> UInt16 {
        guard let word = try controller.readWord(at: address) else { throw I2CError.failed }
        return word
    }

    public func readData(length: Int) throws -> Data {
        guard let data = try controller.readData(at: address, length: length) else { throw I2CError.failed }
        return data
    }

    public func decode<T: I2CReadable>() throws -> T {
        guard let data = try controller.readData(at: address, length: T.dataLength) else { throw I2CError.failed }
        return T(data: data)
    }

    public func writeByte(value: UInt8) throws {
        guard try controller.writeByte(at: address, value: value) else { throw I2CError.failed }
    }

    public func writeWord(value: UInt16) throws {
        guard try controller.writeWord(at: address, value: value) else { throw I2CError.failed }
    }

    public func writeData(value: Data) throws {
        guard try controller.writeData(at: address, value: value) else { throw I2CError.failed }
    }

    public func encode<T>(value: T) throws where T : I2CWritable {
        guard try controller.writeData(at: address, value: value.encodeToData()) else { throw I2CError.failed }
    }

    //
    // SMBus
    //

    public func readByte(command: UInt8) throws -> UInt8 {
        try controller.setCurrentEndpoint(to: address)

        guard let byte = try controller.readByte(command: command) else { throw I2CError.failed }
        return byte
    }

    public func readWord(command: UInt8) throws -> UInt16 {
        try controller.setCurrentEndpoint(to: address)

        guard let word = try controller.readWord(command: command) else { throw I2CError.failed }
        return word
    }

    public func readData(command: UInt8) throws -> Data {
        try controller.setCurrentEndpoint(to: address)

        guard let data = try controller.readData(command: command) else { throw I2CError.failed }
        return data
    }

    public func decode<T: I2CReadable>(command: UInt8) throws -> T {
        try controller.setCurrentEndpoint(to: address)

        guard let data = try controller.readData(command: command) else { throw I2CError.failed }
        return T(data: data)
    }

    public func writeQuick() throws {
        try controller.setCurrentEndpoint(to: address)

        guard try controller.writeQuick() else { throw I2CError.failed }
    }

    public func writeByte(command: UInt8, value: UInt8) throws {
        try controller.setCurrentEndpoint(to: address)

        guard try controller.writeByte(command: command, value: value) else { throw I2CError.failed }
    }

    public func writeWord(command: UInt8, value: UInt16) throws {
        try controller.setCurrentEndpoint(to: address)

        guard try controller.writeWord(command: command, value: value) else { throw I2CError.failed }
    }

    public func writeData(command: UInt8, value: Data) throws {
        try controller.setCurrentEndpoint(to: address)

        guard try controller.writeData(command: command, value: value) else { throw I2CError.failed }
    }

    public func encode<T>(command: UInt8, value: T) throws where T : I2CWritable {
        try controller.setCurrentEndpoint(to: address)

        guard try controller.writeData(command: command, value: value.encodeToData()) else { throw I2CError.failed }
    }
}

struct I2CMessageFlags: OptionSet {
    let rawValue: UInt16

    static let read = I2CMessageFlags(rawValue: 0x0001)
    static let noStart = I2CMessageFlags(rawValue: 0x4000)
}

struct I2CMessage {
    var address: UInt16
    var flags: I2CMessageFlags
    var length: UInt16
    var data: UnsafeMutablePointer<UInt8>?

    init(_ address: UInt16, flags: I2CMessageFlags, length: UInt16, data: UnsafeMutablePointer<UInt8>?) {
        self.address = address
        self.flags = flags
        self.length = length
        self.data = data
    }
}

struct I2CMessageSet {
    var messages: UnsafeMutablePointer<I2CMessage>?
    var count: UInt32

    init(_ messages: UnsafeMutablePointer<I2CMessage>?, count: Int) {
        self.messages = messages
        self.count = UInt32(count)
    }
}

struct SMBusReadWrite {
    let rawValue: UInt8

    private init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    var isRead: Bool {
        get { return self.rawValue != 0 }
    }

    static let read = SMBusReadWrite(rawValue: 1)
    static let write = SMBusReadWrite(rawValue: 0)
}

enum SMBusDataKind: Int32 {
    case quick = 0
    case byte = 1
    case byteData = 2
    case wordData = 3
    case blockData = 5
}

fileprivate struct SMBusData {
    var readOrWrite: SMBusReadWrite
    var command: UInt8
    var dataKind: Int32
    var data: UnsafeMutablePointer<UInt8>?

    init(_ readOrWrite: SMBusReadWrite, command: UInt8, dataKind: SMBusDataKind, data: UnsafeMutablePointer<UInt8>?) {
        self.readOrWrite = readOrWrite
        self.command = command
        self.dataKind = dataKind.rawValue
        self.data = data
    }
}
