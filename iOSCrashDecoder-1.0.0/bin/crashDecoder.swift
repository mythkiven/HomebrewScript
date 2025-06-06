#!/usr/bin/env swift


import Foundation

final class CrashTranslator {
    

    // 在 CrashTranslator 类中添加查找 symbolicatecrash 工具的方法
    func findSymbolicatecrashPaths() -> [String] {
        print("正在查找 symbolicatecrash 工具...")
        
        // 1. 设置环境变量
        let setEnvCommand = "export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer"
        shell(setEnvCommand)
        
        // 2. 查找所有 symbolicatecrash 路径
        let findCommand = "find /Applications/Xcode.app -name symbolicatecrash -type f"
        let result = shell(findCommand)
        
        let paths = result.split(separator: "\n").map { String($0) }
        print("找到 \(paths.count) 个 symbolicatecrash 路径")
        
        return paths
    }

    @discardableResult
    func shellWithStatus(_ command: String) -> (output: String, status: Int32) {
        let task = Process()
        let pipe = Pipe()
        
        task.standardOutput = pipe
        task.standardError = pipe
        task.arguments = ["-c", command]
        task.launchPath = "/bin/zsh"
        task.launch()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        task.waitUntilExit()
        let status = task.terminationStatus
        
        return (output.trimmingCharacters(in: .newlines), status)
    }
    func run(jsonFile: String, outputFile: String) throws {
        _ = shell("pwd")  // 使用 _ 忽略返回值
        // print("Working in \(pwd)")

        let jsonUrl = URL(fileURLWithPath: jsonFile)
        
        guard FileManager.default.fileExists(atPath: jsonUrl.path) else {
            throw NSError(domain: "CrashAnalyzer", code: 3, userInfo: [NSLocalizedDescriptionKey: "JSON文件 \(jsonUrl.path) 不存在!"])
        }
        
        let loadedFile = try String(contentsOfFile: jsonUrl.path, encoding: .utf8)
        var linesInFile = loadedFile.components(separatedBy: "\n")
        let ipsHeader = JSON(parseJSON: linesInFile.removeFirst())
        let payload = JSON(parseJSON: linesInFile.joined(separator: "\n"))
        let content = try self.convert(ipsHeader: ipsHeader, payload: payload)
        
        let outputUrl = URL(fileURLWithPath: outputFile)
        try content.write(to: outputUrl, atomically: true, encoding: .utf8)
        
        print("成功转换文件到: \(outputUrl.path)")
    }
    
    private func convert(ipsHeader: JSON, payload: JSON) throws -> String {

        
        var content = self.buildHeader(ipsHeader, payload)
        let binaryImages = payload["usedImages"]
        
        if let threads = payload["threads"].array {
            for (id, thread) in threads.enumerated() {
                content.append("\n")
                if let name = thread["name"].string ?? thread["queue"].string {
                    content.append("Thread %d name:  %@\n".format(id, name))
                }
                if thread["triggered"].bool ?? false {
                    content.append("Thread %d Crashed:\n".format(id))
                } else {
                    content.append("Thread %d:\n".format(id))
                }
                content.append(self.buildFrameStack(frames: thread["frames"], binaryImages: binaryImages))
            }
        }
        content.append(self.buildBinaryImages(binaryImages))
        return content
    }
    
    private func buildFrameStack(frames: JSON, binaryImages: JSON) -> String {
        var content = ""
        for (id, frame) in (frames.array ?? []).enumerated() {
            let binaryImage = binaryImages[frame["imageIndex"].intValue]
            let address = frame["imageOffset"].intValue + binaryImage["base"].intValue
            content.append("%d".format(id).padding(length: 5))
            content.append(binaryImage["name"].stringValue.padding(length: 40))
            content.append("0x%llx ".format(address))
            if let symbol = frame["symbol"].string, let symbolLocation = frame["symbolLocation"].int {
                content.append("\(symbol) + \(symbolLocation)")
            } else {
                content.append("0x%llx + %d".format(binaryImage["base"].int64Value, frame["imageOffset"].intValue))
            }
            if let sourceFile = frame["sourceFile"].string, let sourceLine = frame["sourceLine"].int {
                content.append(" (\(sourceFile):\(sourceLine))")
            }
            content.append("\n")
        }
        return content
    }
    
    private func buildBinaryImages(_ binaryImages: JSON) -> String {
        var content = "\nBinary Images:\n"
        for image in binaryImages.arrayValue {
            content.append("0x%llx - 0x%llx ".format(image["base"].intValue, image["base"].intValue + image["size"].intValue - 1))
            content.append("%@ %@ ".format(image["name"].stringValue, image["arch"].stringValue))
            content.append("<%@> %@\n".format(image["uuid"].stringValue.replacingOccurrences(of: "-", with: ""), image["path"].stringValue))
        }
        return content
    }
    
    private func buildHeader(_ ipsHeader: JSON, _ payload: JSON) -> String {
        var content = ""
        content.append("Incident Identifier: %@\n".format(ipsHeader["incident_id"].stringValue))
        content.append("CrashReporter Key:   %@\n".format(payload["crashReporterKey"].stringValue))
        content.append("Hardware Model:      %@\n".format(payload["modelCode"].stringValue))
        content.append("Process:             %@ [%@]\n".format(payload["procName"].stringValue, payload["pid"].stringValue))
        content.append("Path:                %@\n".format(payload["procPath"].stringValue))
        if payload["bundleInfo"].exists() {
            let bundleInfo = payload["bundleInfo"]
            content.append("Identifier:          %@\n".format(bundleInfo["CFBundleIdentifier"].stringValue))
            content.append("Version:             %@ (%@)\n"
                            .format(bundleInfo["CFBundleShortVersionString"].stringValue, bundleInfo["CFBundleVersion"].stringValue))
        }
        content.append("Report Version:      104\n")
        content.append("Code Type:           %@ (Native(?))\n".format(payload["cpuType"].stringValue))
        content.append("Role:                %@\n".format(payload["procRole"].stringValue))
        content.append("Parent Process:      %@ [%@]\n".format(payload["parentProc"].stringValue, payload["parentPid"].stringValue))
        content.append("Coalition:           %@ [%@]\n".format(payload["coalitionName"].stringValue, payload["coalitionID"].stringValue))
        content.append("\n")
        content.append("Date/Time:           %@\n".format(payload["captureTime"].stringValue))
        content.append("Launch Time:         %@\n".format(payload["procLaunch"].stringValue))
        content.append("OS Version:          %@\n".format(ipsHeader["os_version"].stringValue))
        content.append("Release Type:        %@\n".format(payload["osVersion"]["releaseType"].stringValue))
        content.append("Baseband Version:    %@\n".format(payload["basebandVersion"].stringValue))
        content.append("\n")
        let exception = payload["exception"]
        content.append("Exception Type:  %@ (%@)\n".format(exception["type"].stringValue, exception["signal"].stringValue))
        content.append("Exception Codes: %@\n".format(exception["codes"].stringValue))
        content.append("Triggered by Thread:  %@\n".format(payload["faultingThread"].stringValue))
        content.append("\n")
        return content
    }
    
    @discardableResult
    func shell(_ command: String) -> String {
        let task = Process()
        let pipe = Pipe()
        
        task.standardOutput = pipe
        task.standardError = pipe
        task.arguments = ["-c", command]
        task.launchPath = "/bin/zsh"
        task.launch()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)!
        
        return output.trimmingCharacters(in: .newlines)
    }
}

extension String {
    func format(_ args: CVarArg...) -> String {
        return String(format: self, arguments: args)
    }

    func padding(length: Int) -> String {
        return self.padding(toLength: length, withPad: " ", startingAt: 0)
    }
}

//  SwiftyJSON.swift
//
//  Copyright (c) 2014 - 2017 Ruoyu Fu, Pinglin Tang
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

// MARK: - Error
// swiftlint:disable line_length
public enum SwiftyJSONError: Int, Swift.Error {
    case unsupportedType = 999
    case indexOutOfBounds = 900
    case elementTooDeep = 902
    case wrongType = 901
    case notExist = 500
    case invalidJSON = 490
}

extension SwiftyJSONError: CustomNSError {

    /// return the error domain of SwiftyJSONError
    public static var errorDomain: String { return "com.swiftyjson.SwiftyJSON" }

    /// return the error code of SwiftyJSONError
    public var errorCode: Int { return self.rawValue }

    /// return the userInfo of SwiftyJSONError
    public var errorUserInfo: [String: Any] {
        switch self {
        case .unsupportedType:
            return [NSLocalizedDescriptionKey: "It is an unsupported type."]
        case .indexOutOfBounds:
            return [NSLocalizedDescriptionKey: "Array Index is out of bounds."]
        case .wrongType:
            return [NSLocalizedDescriptionKey: "Couldn't merge, because the JSONs differ in type on top level."]
        case .notExist:
            return [NSLocalizedDescriptionKey: "Dictionary key does not exist."]
        case .invalidJSON:
            return [NSLocalizedDescriptionKey: "JSON is invalid."]
        case .elementTooDeep:
            return [NSLocalizedDescriptionKey: "Element too deep. Increase maxObjectDepth and make sure there is no reference loop."]
        }
    }
}

// MARK: - JSON Type

/**
JSON's type definitions.

See http://www.json.org
*/
public enum Type: Int {
    case number
    case string
    case bool
    case array
    case dictionary
    case null
    case unknown
}

// MARK: - JSON Base

public struct JSON {

    /**
     Creates a JSON using the data.
    
     - parameter data: The NSData used to convert to json.Top level object in data is an NSArray or NSDictionary
     - parameter opt: The JSON serialization reading options. `[]` by default.
    
     - returns: The created JSON
     */
    public init(data: Data, options opt: JSONSerialization.ReadingOptions = []) throws {
        let object: Any = try JSONSerialization.jsonObject(with: data, options: opt)
        self.init(jsonObject: object)
    }

    /**
     Creates a JSON object
     - note: this does not parse a `String` into JSON, instead use `init(parseJSON: String)`
    
     - parameter object: the object

     - returns: the created JSON object
     */
    public init(_ object: Any) {
        switch object {
        case let object as Data:
            do {
                try self.init(data: object)
            } catch {
                self.init(jsonObject: NSNull())
            }
        default:
            self.init(jsonObject: object)
        }
    }

    /**
     Parses the JSON string into a JSON object
    
     - parameter json: the JSON string
    
     - returns: the created JSON object
    */
    public init(parseJSON jsonString: String) {
        if let data = jsonString.data(using: .utf8) {
            self.init(data)
        } else {
            self.init(NSNull())
        }
    }

    /**
     Creates a JSON using the object.
    
     - parameter jsonObject:  The object must have the following properties: All objects are NSString/String, NSNumber/Int/Float/Double/Bool, NSArray/Array, NSDictionary/Dictionary, or NSNull; All dictionary keys are NSStrings/String; NSNumbers are not NaN or infinity.
    
     - returns: The created JSON
     */
    fileprivate init(jsonObject: Any) {
        object = jsonObject
    }

    /**
     Merges another JSON into this JSON, whereas primitive values which are not present in this JSON are getting added,
     present values getting overwritten, array values getting appended and nested JSONs getting merged the same way.
 
     - parameter other: The JSON which gets merged into this JSON
    
     - throws `ErrorWrongType` if the other JSONs differs in type on the top level.
     */
    public mutating func merge(with other: JSON) throws {
        try self.merge(with: other, typecheck: true)
    }

    /**
     Merges another JSON into this JSON and returns a new JSON, whereas primitive values which are not present in this JSON are getting added,
     present values getting overwritten, array values getting appended and nested JSONS getting merged the same way.
    
     - parameter other: The JSON which gets merged into this JSON
    
     - throws `ErrorWrongType` if the other JSONs differs in type on the top level.
    
     - returns: New merged JSON
     */
    public func merged(with other: JSON) throws -> JSON {
        var merged = self
        try merged.merge(with: other, typecheck: true)
        return merged
    }

    /**
     Private woker function which does the actual merging
     Typecheck is set to true for the first recursion level to prevent total override of the source JSON
     */
     fileprivate mutating func merge(with other: JSON, typecheck: Bool) throws {
        if type == other.type {
            switch type {
            case .dictionary:
                for (key, _) in other {
                    try self[key].merge(with: other[key], typecheck: false)
                }
            case .array:
                self = JSON(arrayValue + other.arrayValue)
            default:
                self = other
            }
        } else {
            if typecheck {
                throw SwiftyJSONError.wrongType
            } else {
                self = other
            }
        }
    }

    /// Private object
    fileprivate var rawArray: [Any] = []
    fileprivate var rawDictionary: [String: Any] = [:]
    fileprivate var rawString: String = ""
    fileprivate var rawNumber: NSNumber = 0
    fileprivate var rawNull: NSNull = NSNull()
    fileprivate var rawBool: Bool = false

    /// JSON type, fileprivate setter
    public fileprivate(set) var type: Type = .null

    /// Error in JSON, fileprivate setter
    public fileprivate(set) var error: SwiftyJSONError?

    /// Object in JSON
    public var object: Any {
        get {
            switch type {
            case .array:      return rawArray
            case .dictionary: return rawDictionary
            case .string:     return rawString
            case .number:     return rawNumber
            case .bool:       return rawBool
            default:          return rawNull
            }
        }
        set {
            error = nil
            switch unwrap(newValue) {
            case let number as NSNumber:
                if number.isBool {
                    type = .bool
                    rawBool = number.boolValue
                } else {
                    type = .number
                    rawNumber = number
                }
            case let string as String:
                type = .string
                rawString = string
            case _ as NSNull:
                type = .null
            case Optional<Any>.none:
                type = .null
            case let array as [Any]:
                type = .array
                rawArray = array
            case let dictionary as [String: Any]:
                type = .dictionary
                rawDictionary = dictionary
            default:
                type = .unknown
                error = SwiftyJSONError.unsupportedType
            }
        }
    }

    /// The static null JSON
    @available(*, unavailable, renamed:"null")
    public static var nullJSON: JSON { return null }
    public static var null: JSON { return JSON(NSNull()) }
}

/// Private method to unwarp an object recursively
private func unwrap(_ object: Any) -> Any {
    switch object {
    case let json as JSON:
        return unwrap(json.object)
    case let array as [Any]:
        return array.map(unwrap)
    case let dictionary as [String: Any]:
        var d = dictionary
        dictionary.forEach { pair in
            d[pair.key] = unwrap(pair.value)
        }
        return d
    default:
        return object
    }
}

public enum Index<T: Any>: Comparable {
    case array(Int)
    case dictionary(DictionaryIndex<String, T>)
    case null

    static public func == (lhs: Index, rhs: Index) -> Bool {
        switch (lhs, rhs) {
        case (.array(let left), .array(let right)):           return left == right
        case (.dictionary(let left), .dictionary(let right)): return left == right
        case (.null, .null):                                  return true
        default:                                              return false
        }
    }

    static public func < (lhs: Index, rhs: Index) -> Bool {
        switch (lhs, rhs) {
        case (.array(let left), .array(let right)):           return left < right
        case (.dictionary(let left), .dictionary(let right)): return left < right
        default:                                              return false
        }
    }
}

public typealias JSONIndex = Index<JSON>
public typealias JSONRawIndex = Index<Any>

extension JSON: Swift.Collection {

    public typealias Index = JSONRawIndex

    public var startIndex: Index {
        switch type {
        case .array:      return .array(rawArray.startIndex)
        case .dictionary: return .dictionary(rawDictionary.startIndex)
        default:          return .null
        }
    }

    public var endIndex: Index {
        switch type {
        case .array:      return .array(rawArray.endIndex)
        case .dictionary: return .dictionary(rawDictionary.endIndex)
        default:          return .null
        }
    }

    public func index(after i: Index) -> Index {
        switch i {
        case .array(let idx):      return .array(rawArray.index(after: idx))
        case .dictionary(let idx): return .dictionary(rawDictionary.index(after: idx))
        default:                   return .null
        }
    }

    public subscript (position: Index) -> (String, JSON) {
        switch position {
        case .array(let idx):      return (String(idx), JSON(rawArray[idx]))
        case .dictionary(let idx): return (rawDictionary[idx].key, JSON(rawDictionary[idx].value))
        default:                   return ("", JSON.null)
        }
    }
}

// MARK: - Subscript

/**
 *  To mark both String and Int can be used in subscript.
 */
public enum JSONKey {
    case index(Int)
    case key(String)
}

public protocol JSONSubscriptType {
    var jsonKey: JSONKey { get }
}

extension Int: JSONSubscriptType {
    public var jsonKey: JSONKey {
        return JSONKey.index(self)
    }
}

extension String: JSONSubscriptType {
    public var jsonKey: JSONKey {
        return JSONKey.key(self)
    }
}

extension JSON {

    /// If `type` is `.array`, return json whose object is `array[index]`, otherwise return null json with error.
    fileprivate subscript(index index: Int) -> JSON {
        get {
            if type != .array {
                var r = JSON.null
                r.error = self.error ?? SwiftyJSONError.wrongType
                return r
            } else if rawArray.indices.contains(index) {
                return JSON(rawArray[index])
            } else {
                var r = JSON.null
                r.error = SwiftyJSONError.indexOutOfBounds
                return r
            }
        }
        set {
            if type == .array &&
                rawArray.indices.contains(index) &&
                newValue.error == nil {
                rawArray[index] = newValue.object
            }
        }
    }

    /// If `type` is `.dictionary`, return json whose object is `dictionary[key]` , otherwise return null json with error.
    fileprivate subscript(key key: String) -> JSON {
        get {
            var r = JSON.null
            if type == .dictionary {
                if let o = rawDictionary[key] {
                    r = JSON(o)
                } else {
                    r.error = SwiftyJSONError.notExist
                }
            } else {
                r.error = self.error ?? SwiftyJSONError.wrongType
            }
            return r
        }
        set {
            if type == .dictionary && newValue.error == nil {
                rawDictionary[key] = newValue.object
            }
        }
    }

    /// If `sub` is `Int`, return `subscript(index:)`; If `sub` is `String`,  return `subscript(key:)`.
    fileprivate subscript(sub sub: JSONSubscriptType) -> JSON {
        get {
            switch sub.jsonKey {
            case .index(let index): return self[index: index]
            case .key(let key):     return self[key: key]
            }
        }
        set {
            switch sub.jsonKey {
            case .index(let index): self[index: index] = newValue
            case .key(let key):     self[key: key] = newValue
            }
        }
    }

    /**
     Find a json in the complex data structures by using array of Int and/or String as path.
    
     Example:
    
     ```
     let json = JSON[data]
     let path = [9,"list","person","name"]
     let name = json[path]
     ```
    
     The same as: let name = json[9]["list"]["person"]["name"]
    
     - parameter path: The target json's path.
    
     - returns: Return a json found by the path or a null json with error
     */
    public subscript(path: [JSONSubscriptType]) -> JSON {
        get {
            return path.reduce(self) { $0[sub: $1] }
        }
        set {
            switch path.count {
            case 0: return
            case 1: self[sub:path[0]].object = newValue.object
            default:
                var aPath = path
                aPath.remove(at: 0)
                var nextJSON = self[sub: path[0]]
                nextJSON[aPath] = newValue
                self[sub: path[0]] = nextJSON
            }
        }
    }

    /**
     Find a json in the complex data structures by using array of Int and/or String as path.

     - parameter path: The target json's path. Example:

     let name = json[9,"list","person","name"]

     The same as: let name = json[9]["list"]["person"]["name"]

     - returns: Return a json found by the path or a null json with error
     */
    public subscript(path: JSONSubscriptType...) -> JSON {
        get {
            return self[path]
        }
        set {
            self[path] = newValue
        }
    }
}

// MARK: - LiteralConvertible

extension JSON: Swift.ExpressibleByStringLiteral {

    public init(stringLiteral value: StringLiteralType) {
        self.init(value)
    }

    public init(extendedGraphemeClusterLiteral value: StringLiteralType) {
        self.init(value)
    }

    public init(unicodeScalarLiteral value: StringLiteralType) {
        self.init(value)
    }
}

extension JSON: Swift.ExpressibleByIntegerLiteral {

    public init(integerLiteral value: IntegerLiteralType) {
        self.init(value)
    }
}

extension JSON: Swift.ExpressibleByBooleanLiteral {

    public init(booleanLiteral value: BooleanLiteralType) {
        self.init(value)
    }
}

extension JSON: Swift.ExpressibleByFloatLiteral {

    public init(floatLiteral value: FloatLiteralType) {
        self.init(value)
    }
}

extension JSON: Swift.ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, Any)...) {
        let dictionary = elements.reduce(into: [String: Any](), { $0[$1.0] = $1.1})
        self.init(dictionary)
    }
}

extension JSON: Swift.ExpressibleByArrayLiteral {

    public init(arrayLiteral elements: Any...) {
        self.init(elements)
    }
}

// MARK: - Raw

extension JSON: Swift.RawRepresentable {

    public init?(rawValue: Any) {
        if JSON(rawValue).type == .unknown {
            return nil
        } else {
            self.init(rawValue)
        }
    }

    public var rawValue: Any {
        return object
    }

    public func rawData(options opt: JSONSerialization.WritingOptions = JSONSerialization.WritingOptions(rawValue: 0)) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw SwiftyJSONError.invalidJSON
        }

        return try JSONSerialization.data(withJSONObject: object, options: opt)
    }

    public func rawString(_ encoding: String.Encoding = .utf8, options opt: JSONSerialization.WritingOptions = .prettyPrinted) -> String? {
        do {
            return try _rawString(encoding, options: [.jsonSerialization: opt])
        } catch {
            print("Could not serialize object to JSON because:", error.localizedDescription)
            return nil
        }
    }

    public func rawString(_ options: [writingOptionsKeys: Any]) -> String? {
        let encoding = options[.encoding] as? String.Encoding ?? String.Encoding.utf8
        let maxObjectDepth = options[.maxObjextDepth] as? Int ?? 10
        do {
            return try _rawString(encoding, options: options, maxObjectDepth: maxObjectDepth)
        } catch {
            print("Could not serialize object to JSON because:", error.localizedDescription)
            return nil
        }
    }

    fileprivate func _rawString(_ encoding: String.Encoding = .utf8, options: [writingOptionsKeys: Any], maxObjectDepth: Int = 10) throws -> String? {
        guard maxObjectDepth > 0 else { throw SwiftyJSONError.invalidJSON }
        switch type {
        case .dictionary:
            do {
                if !(options[.castNilToNSNull] as? Bool ?? false) {
                    let jsonOption = options[.jsonSerialization] as? JSONSerialization.WritingOptions ?? JSONSerialization.WritingOptions.prettyPrinted
                    let data = try rawData(options: jsonOption)
                    return String(data: data, encoding: encoding)
                }

                guard let dict = object as? [String: Any?] else {
                    return nil
                }
                let body = try dict.keys.map { key throws -> String in
                    guard let value = dict[key] else {
                        return "\"\(key)\": null"
                    }
                    guard let unwrappedValue = value else {
                        return "\"\(key)\": null"
                    }

                    let nestedValue = JSON(unwrappedValue)
                    guard let nestedString = try nestedValue._rawString(encoding, options: options, maxObjectDepth: maxObjectDepth - 1) else {
                        throw SwiftyJSONError.elementTooDeep
                    }
                    if nestedValue.type == .string {
                        return "\"\(key)\": \"\(nestedString.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
                    } else {
                        return "\"\(key)\": \(nestedString)"
                    }
                }

                return "{\(body.joined(separator: ","))}"
            } catch _ {
                return nil
            }
        case .array:
            do {
                if !(options[.castNilToNSNull] as? Bool ?? false) {
                    let jsonOption = options[.jsonSerialization] as? JSONSerialization.WritingOptions ?? JSONSerialization.WritingOptions.prettyPrinted
                    let data = try rawData(options: jsonOption)
                    return String(data: data, encoding: encoding)
                }

                guard let array = object as? [Any?] else {
                    return nil
                }
                let body = try array.map { value throws -> String in
                    guard let unwrappedValue = value else {
                        return "null"
                    }

                    let nestedValue = JSON(unwrappedValue)
                    guard let nestedString = try nestedValue._rawString(encoding, options: options, maxObjectDepth: maxObjectDepth - 1) else {
                        throw SwiftyJSONError.invalidJSON
                    }
                    if nestedValue.type == .string {
                        return "\"\(nestedString.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
                    } else {
                        return nestedString
                    }
                }

                return "[\(body.joined(separator: ","))]"
            } catch _ {
                return nil
            }
        case .string: return rawString
        case .number: return rawNumber.stringValue
        case .bool:   return rawBool.description
        case .null:   return "null"
        default:      return nil
        }
    }
}

// MARK: - Printable, DebugPrintable

extension JSON: Swift.CustomStringConvertible, Swift.CustomDebugStringConvertible {

    public var description: String {
        return rawString(options: .prettyPrinted) ?? "unknown"
    }

    public var debugDescription: String {
        return description
    }
}

// MARK: - Array

extension JSON {

    //Optional [JSON]
    public var array: [JSON]? {
        return type == .array ? rawArray.map { JSON($0) } : nil
    }

    //Non-optional [JSON]
    public var arrayValue: [JSON] {
        return self.array ?? []
    }

    //Optional [Any]
    public var arrayObject: [Any]? {
        get {
            switch type {
            case .array: return rawArray
            default:     return nil
            }
        }
        set {
            self.object = newValue ?? NSNull()
        }
    }
}

// MARK: - Dictionary

extension JSON {

    //Optional [String : JSON]
    public var dictionary: [String: JSON]? {
        if type == .dictionary {
            var d = [String: JSON](minimumCapacity: rawDictionary.count)
            rawDictionary.forEach { pair in
                d[pair.key] = JSON(pair.value)
            }
            return d
        } else {
            return nil
        }
    }

    //Non-optional [String : JSON]
    public var dictionaryValue: [String: JSON] {
        return dictionary ?? [:]
    }

    //Optional [String : Any]

    public var dictionaryObject: [String: Any]? {
        get {
            switch type {
            case .dictionary: return rawDictionary
            default:          return nil
            }
        }
        set {
            object = newValue ?? NSNull()
        }
    }
}

// MARK: - Bool

extension JSON { // : Swift.Bool

    //Optional bool
    public var bool: Bool? {
        get {
            switch type {
            case .bool: return rawBool
            default:    return nil
            }
        }
        set {
            object = newValue ?? NSNull()
        }
    }

    //Non-optional bool
    public var boolValue: Bool {
        get {
            switch type {
            case .bool:   return rawBool
            case .number: return rawNumber.boolValue
            case .string: return ["true", "y", "t", "yes", "1"].contains { rawString.caseInsensitiveCompare($0) == .orderedSame }
            default:      return false
            }
        }
        set {
            object = newValue
        }
    }
}

// MARK: - String

extension JSON {

    //Optional string
    public var string: String? {
        get {
            switch type {
            case .string: return object as? String
            default:      return nil
            }
        }
        set {
            object = newValue ?? NSNull()
        }
    }

    //Non-optional string
    public var stringValue: String {
        get {
            switch type {
            case .string: return object as? String ?? ""
            case .number: return rawNumber.stringValue
            case .bool:   return (object as? Bool).map { String($0) } ?? ""
            default:      return ""
            }
        }
        set {
            object = newValue
        }
    }
}

// MARK: - Number

extension JSON {

    //Optional number
    public var number: NSNumber? {
        get {
            switch type {
            case .number: return rawNumber
            case .bool:   return NSNumber(value: rawBool ? 1 : 0)
            default:      return nil
            }
        }
        set {
            object = newValue ?? NSNull()
        }
    }

    //Non-optional number
    public var numberValue: NSNumber {
        get {
            switch type {
            case .string:
                let decimal = NSDecimalNumber(string: object as? String)
                return decimal == .notANumber ? .zero : decimal
            case .number: return object as? NSNumber ?? NSNumber(value: 0)
            case .bool: return NSNumber(value: rawBool ? 1 : 0)
            default: return NSNumber(value: 0.0)
            }
        }
        set {
            object = newValue
        }
    }
}

// MARK: - Null

extension JSON {

    public var null: NSNull? {
        set {
            object = NSNull()
        }
        get {
            switch type {
            case .null: return rawNull
            default:    return nil
            }
        }
    }
    public func exists() -> Bool {
        if let errorValue = error, (400...1000).contains(errorValue.errorCode) {
            return false
        }
        return true
    }
}

// MARK: - URL

extension JSON {

    //Optional URL
    public var url: URL? {
        get {
            switch type {
            case .string:
                // Check for existing percent escapes first to prevent double-escaping of % character
                if rawString.range(of: "%[0-9A-Fa-f]{2}", options: .regularExpression, range: nil, locale: nil) != nil {
                    return Foundation.URL(string: rawString)
                } else if let encodedString_ = rawString.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) {
                    // We have to use `Foundation.URL` otherwise it conflicts with the variable name.
                    return Foundation.URL(string: encodedString_)
                } else {
                    return nil
                }
            default:
                return nil
            }
        }
        set {
            object = newValue?.absoluteString ?? NSNull()
        }
    }
}

// MARK: - Int, Double, Float, Int8, Int16, Int32, Int64

extension JSON {

    public var double: Double? {
        get {
            return number?.doubleValue
        }
        set {
            if let newValue = newValue {
                object = NSNumber(value: newValue)
            } else {
                object = NSNull()
            }
        }
    }

    public var doubleValue: Double {
        get {
            return numberValue.doubleValue
        }
        set {
            object = NSNumber(value: newValue)
        }
    }

    public var float: Float? {
        get {
            return number?.floatValue
        }
        set {
            if let newValue = newValue {
                object = NSNumber(value: newValue)
            } else {
                object = NSNull()
            }
        }
    }

    public var floatValue: Float {
        get {
            return numberValue.floatValue
        }
        set {
            object = NSNumber(value: newValue)
        }
    }

    public var int: Int? {
        get {
            return number?.intValue
        }
        set {
            if let newValue = newValue {
                object = NSNumber(value: newValue)
            } else {
                object = NSNull()
            }
        }
    }

    public var intValue: Int {
        get {
            return numberValue.intValue
        }
        set {
            object = NSNumber(value: newValue)
        }
    }

    public var uInt: UInt? {
        get {
            return number?.uintValue
        }
        set {
            if let newValue = newValue {
                object = NSNumber(value: newValue)
            } else {
                object = NSNull()
            }
        }
    }

    public var uIntValue: UInt {
        get {
            return numberValue.uintValue
        }
        set {
            object = NSNumber(value: newValue)
        }
    }

    public var int8: Int8? {
        get {
            return number?.int8Value
        }
        set {
            if let newValue = newValue {
                object = NSNumber(value: Int(newValue))
            } else {
                object =  NSNull()
            }
        }
    }

    public var int8Value: Int8 {
        get {
            return numberValue.int8Value
        }
        set {
            object = NSNumber(value: Int(newValue))
        }
    }

    public var uInt8: UInt8? {
        get {
            return number?.uint8Value
        }
        set {
            if let newValue = newValue {
                object = NSNumber(value: newValue)
            } else {
                object =  NSNull()
            }
        }
    }

    public var uInt8Value: UInt8 {
        get {
            return numberValue.uint8Value
        }
        set {
            object = NSNumber(value: newValue)
        }
    }

    public var int16: Int16? {
        get {
            return number?.int16Value
        }
        set {
            if let newValue = newValue {
                object = NSNumber(value: newValue)
            } else {
                object =  NSNull()
            }
        }
    }

    public var int16Value: Int16 {
        get {
            return numberValue.int16Value
        }
        set {
            object = NSNumber(value: newValue)
        }
    }

    public var uInt16: UInt16? {
        get {
            return number?.uint16Value
        }
        set {
            if let newValue = newValue {
                object = NSNumber(value: newValue)
            } else {
                object =  NSNull()
            }
        }
    }

    public var uInt16Value: UInt16 {
        get {
            return numberValue.uint16Value
        }
        set {
            object = NSNumber(value: newValue)
        }
    }

    public var int32: Int32? {
        get {
            return number?.int32Value
        }
        set {
            if let newValue = newValue {
                object = NSNumber(value: newValue)
            } else {
                object =  NSNull()
            }
        }
    }

    public var int32Value: Int32 {
        get {
            return numberValue.int32Value
        }
        set {
            object = NSNumber(value: newValue)
        }
    }

    public var uInt32: UInt32? {
        get {
            return number?.uint32Value
        }
        set {
            if let newValue = newValue {
                object = NSNumber(value: newValue)
            } else {
                object =  NSNull()
            }
        }
    }

    public var uInt32Value: UInt32 {
        get {
            return numberValue.uint32Value
        }
        set {
            object = NSNumber(value: newValue)
        }
    }

    public var int64: Int64? {
        get {
            return number?.int64Value
        }
        set {
            if let newValue = newValue {
                object = NSNumber(value: newValue)
            } else {
                object =  NSNull()
            }
        }
    }

    public var int64Value: Int64 {
        get {
            return numberValue.int64Value
        }
        set {
            object = NSNumber(value: newValue)
        }
    }

    public var uInt64: UInt64? {
        get {
            return number?.uint64Value
        }
        set {
            if let newValue = newValue {
                object = NSNumber(value: newValue)
            } else {
                object =  NSNull()
            }
        }
    }

    public var uInt64Value: UInt64 {
        get {
            return numberValue.uint64Value
        }
        set {
            object = NSNumber(value: newValue)
        }
    }
}

// MARK: - Comparable

extension JSON: Swift.Comparable {}

public func == (lhs: JSON, rhs: JSON) -> Bool {

    switch (lhs.type, rhs.type) {
    case (.number, .number): return lhs.rawNumber == rhs.rawNumber
    case (.string, .string): return lhs.rawString == rhs.rawString
    case (.bool, .bool):     return lhs.rawBool == rhs.rawBool
    case (.array, .array):   return lhs.rawArray as NSArray == rhs.rawArray as NSArray
    case (.dictionary, .dictionary): return lhs.rawDictionary as NSDictionary == rhs.rawDictionary as NSDictionary
    case (.null, .null):     return true
    default:                 return false
    }
}

public func <= (lhs: JSON, rhs: JSON) -> Bool {

    switch (lhs.type, rhs.type) {
    case (.number, .number): return lhs.rawNumber <= rhs.rawNumber
    case (.string, .string): return lhs.rawString <= rhs.rawString
    case (.bool, .bool):     return lhs.rawBool == rhs.rawBool
    case (.array, .array):   return lhs.rawArray as NSArray == rhs.rawArray as NSArray
    case (.dictionary, .dictionary): return lhs.rawDictionary as NSDictionary == rhs.rawDictionary as NSDictionary
    case (.null, .null):     return true
    default:                 return false
    }
}

public func >= (lhs: JSON, rhs: JSON) -> Bool {

    switch (lhs.type, rhs.type) {
    case (.number, .number): return lhs.rawNumber >= rhs.rawNumber
    case (.string, .string): return lhs.rawString >= rhs.rawString
    case (.bool, .bool):     return lhs.rawBool == rhs.rawBool
    case (.array, .array):   return lhs.rawArray as NSArray == rhs.rawArray as NSArray
    case (.dictionary, .dictionary): return lhs.rawDictionary as NSDictionary == rhs.rawDictionary as NSDictionary
    case (.null, .null):     return true
    default:                 return false
    }
}

public func > (lhs: JSON, rhs: JSON) -> Bool {

    switch (lhs.type, rhs.type) {
    case (.number, .number): return lhs.rawNumber > rhs.rawNumber
    case (.string, .string): return lhs.rawString > rhs.rawString
    default:                 return false
    }
}

public func < (lhs: JSON, rhs: JSON) -> Bool {

    switch (lhs.type, rhs.type) {
    case (.number, .number): return lhs.rawNumber < rhs.rawNumber
    case (.string, .string): return lhs.rawString < rhs.rawString
    default:                 return false
    }
}

private let trueNumber = NSNumber(value: true)
private let falseNumber = NSNumber(value: false)
private let trueObjCType = String(cString: trueNumber.objCType)
private let falseObjCType = String(cString: falseNumber.objCType)

// MARK: - NSNumber: Comparable

extension NSNumber {
    fileprivate var isBool: Bool {
        let objCType = String(cString: self.objCType)
        if (self.compare(trueNumber) == .orderedSame && objCType == trueObjCType) || (self.compare(falseNumber) == .orderedSame && objCType == falseObjCType) {
            return true
        } else {
            return false
        }
    }
}

func == (lhs: NSNumber, rhs: NSNumber) -> Bool {
    switch (lhs.isBool, rhs.isBool) {
    case (false, true): return false
    case (true, false): return false
    default:            return lhs.compare(rhs) == .orderedSame
    }
}

func != (lhs: NSNumber, rhs: NSNumber) -> Bool {
    return !(lhs == rhs)
}

func < (lhs: NSNumber, rhs: NSNumber) -> Bool {

    switch (lhs.isBool, rhs.isBool) {
    case (false, true): return false
    case (true, false): return false
    default:            return lhs.compare(rhs) == .orderedAscending
    }
}

func > (lhs: NSNumber, rhs: NSNumber) -> Bool {

    switch (lhs.isBool, rhs.isBool) {
    case (false, true): return false
    case (true, false): return false
    default:            return lhs.compare(rhs) == ComparisonResult.orderedDescending
    }
}

func <= (lhs: NSNumber, rhs: NSNumber) -> Bool {

    switch (lhs.isBool, rhs.isBool) {
    case (false, true): return false
    case (true, false): return false
    default:            return lhs.compare(rhs) != .orderedDescending
    }
}

func >= (lhs: NSNumber, rhs: NSNumber) -> Bool {

    switch (lhs.isBool, rhs.isBool) {
    case (false, true): return false
    case (true, false): return false
    default:            return lhs.compare(rhs) != .orderedAscending
    }
}

public enum writingOptionsKeys {
    case jsonSerialization
    case castNilToNSNull
    case maxObjextDepth
    case encoding
}

// MARK: - JSON: Codable
extension JSON: Codable {
    private static var codableTypes: [Codable.Type] {
        return [
            Bool.self,
            Int.self,
            Int8.self,
            Int16.self,
            Int32.self,
            Int64.self,
            UInt.self,
            UInt8.self,
            UInt16.self,
            UInt32.self,
            UInt64.self,
            Double.self,
            String.self,
            [JSON].self,
            [String: JSON].self
        ]
    }
    public init(from decoder: Decoder) throws {
        var object: Any?

        if let container = try? decoder.singleValueContainer(), !container.decodeNil() {
            for type in JSON.codableTypes {
                if object != nil {
                    break
                }
                // try to decode value
                switch type {
                case let boolType as Bool.Type:
                    object = try? container.decode(boolType)
                case let intType as Int.Type:
                    object = try? container.decode(intType)
                case let int8Type as Int8.Type:
                    object = try? container.decode(int8Type)
                case let int32Type as Int32.Type:
                    object = try? container.decode(int32Type)
                case let int64Type as Int64.Type:
                    object = try? container.decode(int64Type)
                case let uintType as UInt.Type:
                    object = try? container.decode(uintType)
                case let uint8Type as UInt8.Type:
                    object = try? container.decode(uint8Type)
                case let uint16Type as UInt16.Type:
                    object = try? container.decode(uint16Type)
                case let uint32Type as UInt32.Type:
                    object = try? container.decode(uint32Type)
                case let uint64Type as UInt64.Type:
                    object = try? container.decode(uint64Type)
                case let doubleType as Double.Type:
                    object = try? container.decode(doubleType)
                case let stringType as String.Type:
                    object = try? container.decode(stringType)
                case let jsonValueArrayType as [JSON].Type:
                    object = try? container.decode(jsonValueArrayType)
                case let jsonValueDictType as [String: JSON].Type:
                    object = try? container.decode(jsonValueDictType)
                default:
                    break
                }
            }
        }
        self.init(object ?? NSNull())
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if object is NSNull {
            try container.encodeNil()
            return
        }
        switch object {
        case let intValue as Int:
            try container.encode(intValue)
        case let int8Value as Int8:
            try container.encode(int8Value)
        case let int32Value as Int32:
            try container.encode(int32Value)
        case let int64Value as Int64:
            try container.encode(int64Value)
        case let uintValue as UInt:
            try container.encode(uintValue)
        case let uint8Value as UInt8:
            try container.encode(uint8Value)
        case let uint16Value as UInt16:
            try container.encode(uint16Value)
        case let uint32Value as UInt32:
            try container.encode(uint32Value)
        case let uint64Value as UInt64:
            try container.encode(uint64Value)
        case let doubleValue as Double:
            try container.encode(doubleValue)
        case let boolValue as Bool:
            try container.encode(boolValue)
        case let stringValue as String:
            try container.encode(stringValue)
        case is [Any]:
            let jsonValueArray = array ?? []
            try container.encode(jsonValueArray)
        case is [String: Any]:
            let jsonValueDictValue = dictionary ?? [:]
            try container.encode(jsonValueDictValue)
        default:
            break
        }
    }
}

// 主入口点
let arguments = CommandLine.arguments

// 函数：显示使用帮助
func printUsage() {
    print("使用方法:")
    print("1. 处理单个文件:")
    print("   crashDecoder -i 崩溃文件.ips -o 输出文件.crash")
    print("2. 处理整个文件夹:")
    print("   crashDecoder -folder /path/to/crash/folder")
    print("   或直接:")
    print("   crashDecoder /path/to/crash/folder")
    print("\n选项:")
    print("   -h, --help     显示此帮助信息")
    print("   -v, --version  显示版本信息")
}

// 解析命令行参数
var i = 1
var jsonFile: String? = nil
var outputFile: String? = nil
var folderPath: String? = nil

// 首先检查是否只传入了一个参数，且该参数不是以'-'开头的选项
if arguments.count == 2 && !arguments[1].hasPrefix("-") {
    // 假定这是一个文件夹路径
    folderPath = arguments[1]
} else {
    // 否则解析常规参数
    while i < arguments.count {
        switch arguments[i] {
        case "-i":
            if i + 1 < arguments.count {
                jsonFile = arguments[i + 1]
                i += 2
            } else {
                print("错误: -i 选项需要提供文件路径")
                printUsage()
                exit(1)
            }
        case "-o":
            if i + 1 < arguments.count {
                outputFile = arguments[i + 1]
                i += 2
            } else {
                print("错误: -o 选项需要提供文件路径")
                printUsage()
                exit(1)
            }
        case "-folder", "--folder":
            if i + 1 < arguments.count {
                folderPath = arguments[i + 1]
                i += 2
            } else {
                print("错误: 文件夹选项需要提供路径")
                printUsage()
                exit(1)
            }
        case "-h", "--help":
            printUsage()
            exit(0)
        case "-v", "--version":
            print("崩溃日志分析工具 v1.0.0")
            exit(0)
        default:
            print("未知选项: \(arguments[i])")
            printUsage()
            exit(1)
        }
    }
}

// 解决：防止显示全部代码
// 使用特殊标记将脚本内容与主逻辑区分开
// 这里添加一个main函数并调用它，防止整个文件被当作输出展示
func main() {
    // 处理逻辑
    if let folder = folderPath {
        print("处理文件夹: \(folder)")
        do {
            try processFolder(folderPath: folder)
            print("文件夹处理完成")
            exit(0)
        } catch {
            print("处理文件夹时出错: \(error.localizedDescription)")
            exit(1)
        }
    } else if let json = jsonFile, let output = outputFile {
        print("处理文件: \(json) -> \(output)")
        do {
            try CrashTranslator().run(jsonFile: json, outputFile: output)
            print("文件处理完成")
            exit(0)
        } catch {
            print("处理文件时出错: \(error.localizedDescription)")
            exit(1)
        }
    } else {
        printUsage()
        exit(1)
    }
}

// 实际执行主函数
main()

func processFolder(folderPath: String) throws {
    print("处理文件夹: \(folderPath)")
    
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    
    // 检查路径是否存在且是文件夹
    guard fileManager.fileExists(atPath: folderPath, isDirectory: &isDirectory), 
          isDirectory.boolValue else {
        throw NSError(domain: "CrashAnalyzer", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(folderPath) 不是一个有效的文件夹"])
    }
    
    // 获取文件夹中的所有文件 - 修复：移除guard let，因为该方法返回非可选类型
    let files: [String]
    do {
        files = try fileManager.contentsOfDirectory(atPath: folderPath)
    } catch {
        throw NSError(domain: "CrashAnalyzer", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法读取文件夹内容: \(error.localizedDescription)"])
    }
    
    // 过滤出.ips文件
    let ipsFiles = files.filter { $0.hasSuffix(".ips") }
    
    if ipsFiles.isEmpty {
        print("没有找到.ips文件")
        return
    }
    
    print("找到 \(ipsFiles.count) 个.ips文件...")
    let translator = CrashTranslator()
    
    for (index, ipsFile) in ipsFiles.enumerated() {
        let ipsPath = (folderPath as NSString).appendingPathComponent(ipsFile)
        let crashFile = ipsPath.replacingOccurrences(of: ".ips", with: ".crash")
        
        print("[\(index+1)/\(ipsFiles.count)] 处理文件: \(ipsFile)")
        // 修复：添加try关键字，因为run方法会抛出错误
        do {
            try translator.run(jsonFile: ipsPath, outputFile: crashFile)
        } catch {
            print("处理文件失败: \(ipsFile), 错误: \(error.localizedDescription)")
            // 继续处理下一个文件而不中断整个流程
        }
    }
    
    print("所有.ips文件转换为.crash文件完成!")
    
    // 在这里重新获取文件列表，确保包含新转换的 .crash 文件
    let updatedFiles = (try? fileManager.contentsOfDirectory(atPath: folderPath)) ?? []
    
    // 查找文件夹中的所有.dSYM文件
    var dsymFiles: [String] = []
    let allContents = (try? fileManager.subpathsOfDirectory(atPath: folderPath)) ?? []
    
    for item in allContents {
        if item.hasSuffix(".dSYM") && item.contains("/") == false {
            let fullPath = (folderPath as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                dsymFiles.append(fullPath)
            }
        }
    }
    
    print("找到 \(dsymFiles.count) 个.dSYM文件")
    for dsymFile in dsymFiles {
        print("  - \(dsymFile)")
    }
    
    // 执行符号化处理
    if !dsymFiles.isEmpty {
        print("开始符号化处理...")
        
        // 使用更新后的文件列表查找所有 .crash 文件
        let crashFiles = updatedFiles.filter { $0.hasSuffix(".crash") }
        print("找到 \(crashFiles.count) 个需要符号化的.crash文件")
        for crashFile in crashFiles {
            print("  - \(crashFile)")
        }
        
        if crashFiles.isEmpty {
            print("没有找到.crash文件，跳过符号化步骤")
            print("所有处理完成!")
            return
        }
        
        // 查找所有可用的 symbolicatecrash 路径
        let symbolicatecrashPaths = translator.findSymbolicatecrashPaths()
        
        if symbolicatecrashPaths.isEmpty {
            print("错误: 未找到 symbolicatecrash 工具")
            return
        }
        
        // 尝试每个找到的 symbolicatecrash 路径
        var anySucceeded = false
        
        for (pathIndex, symbolicatecrashPath) in symbolicatecrashPaths.enumerated() {
            print("尝试使用 symbolicatecrash 路径 [\(pathIndex+1)/\(symbolicatecrashPaths.count)]: \(symbolicatecrashPath)")
            
            var allSucceeded = true
            
            // 对每个 crash 文件进行单独处理
            for crashFile in crashFiles {
                let crashFilePath = (folderPath as NSString).appendingPathComponent(crashFile)
                let tempOutputPath = crashFilePath + ".temp"
                
                print("正在符号化: \(crashFile)")
                
                // 构建 symbolicatecrash 命令
                var command = "export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && "
                command += "\(symbolicatecrashPath) \"\(crashFilePath)\""
                
                // 添加所有.dSYM文件
                for dsymFile in dsymFiles {
                    command += " \"\(dsymFile)\""
                }
                
                // 添加输出重定向到临时文件
                command += " > \"\(tempOutputPath)\""
                
                // 执行符号化命令
                let (result, status) = translator.shellWithStatus(command)
                
                if status == 0 && fileManager.fileExists(atPath: tempOutputPath) {
                    // 如果成功，将临时文件移动到原始 crash 文件位置
                    do {
                        // 删除原始文件
                        if fileManager.fileExists(atPath: crashFilePath) {
                            try fileManager.removeItem(atPath: crashFilePath)
                        }
                        // 将符号化的结果移动到原位置
                        try fileManager.moveItem(atPath: tempOutputPath, toPath: crashFilePath)
                        print("✓ 成功符号化: \(crashFile)")
                        anySucceeded = true
                    } catch {
                        print("✗ 移动文件失败: \(error)")
                        allSucceeded = false
                    }
                } else {
                    print("✗ 符号化失败: \(crashFile)")
                    print("  错误信息: \(result)")
                    print("  状态码: \(status)")
                    
                    // 清理临时文件
                    if fileManager.fileExists(atPath: tempOutputPath) {
                        try? fileManager.removeItem(atPath: tempOutputPath)
                    }
                    
                    allSucceeded = false
                }
            }
            
            // 如果当前路径成功处理了所有文件，就不需要尝试下一个路径
            if allSucceeded {
                print("使用路径 \(symbolicatecrashPath) 成功处理了所有文件")
                break
            } else if pathIndex < symbolicatecrashPaths.count - 1 {
                print("尝试使用下一个 symbolicatecrash 路径...")
            }
        }
        
        if anySucceeded {
            print("所有或部分文件已成功符号化")
        } else {
            print("所有 symbolicatecrash 路径都尝试失败")
        }
        
        print("所有处理完成!")
    }
}

if #file == CommandLine.arguments[0] {
    main()
}