//
//  main.swift
//  SwiftGodot/Generator
//
//  Created by Miguel de Icaza on 5/20/20.
//  Copyright © 2020-2023 Miguel de Icaza. MIT Licensed
//
import Foundation

// IF we want a single file, or one file per type
var singleFile = true

var args = CommandLine.arguments

let jsonFile = args.count > 1 ? args [1] : "/Users/miguel/cvs/godot-master/extension_api.json"
var generatorOutput = args.count > 2 ? args [2] : "/Users/miguel/cvs/SwiftGodot/DEBUG"
var docRoot =  args.count > 3 ? args [3] : "/Users/miguel/cvs/godot-master/doc"

let outputDir = args.count > 2 ? args [2] : generatorOutput

print ("Usage is: generator [godot-main-directory [output-directory]]")
print ("where godot-main-directory contains api.json and builtin-api.json")
print ("If unspecified, this will default to the built-in versions")

let jsonData = try! Data(contentsOf: URL(fileURLWithPath: jsonFile))
let jsonApi = try! JSONDecoder().decode(JGodotExtensionAPI.self, from: jsonData)

// Determines whether a built-in type is defined as a structure, this means:
// that it has fields and does not have a "handle" pointer to the native object
var isStructMap: [String:Bool] = [:]

// Where we accumulate our output for the p/b routines
var result = ""
var indentStr = ""          // The current indentation string, based on `indent`
var indent = 0 {
    didSet {
        indentStr = String (repeating: "    ", count: indent)
    }
}

// Prints the string, indenting any newlines with the current indentation
func p (_ str: String) {
    for x in str.split(separator: "\n", omittingEmptySubsequences: false) {
        print ("\(indentStr)\(x)", to: &result)
    }
}

// Prints a block, automatically indents the code in the closure
func b (_ str: String, suffix: String = "", block: () -> ()) {
    p (str + " {")
    indent += 1
    block ()
    indent -= 1
    p ("}\(suffix)\n")
}

func dropMatchingPrefix (_ enumName: String, _ enumKey: String) -> String {
    let snake = snakeToCamel (enumKey)
    if snake.lowercased().starts(with: enumName.lowercased()) {
        if snake.count == enumName.count {
            return snake
        }
        let ret = String (snake [snake.index (snake.startIndex, offsetBy: enumName.count)...])
        if let f = ret.first {
            if f.isNumber {
                return snake
            }
        }
        if ret == "" {
            return snake
        }
        return ret.first!.lowercased() + ret.dropFirst()
    }
    return snake
}

var globalEnums: [String: JGodotGlobalEnumElement] = [:]

func generateEnums (cdef: JClassInfo?, values: [JGodotGlobalEnumElement], constantDocs: [DocConstant]? , prefix: String?) {
    
    for enumDef in values {
        if enumDef.isBitfield ?? false {
            b ("public struct \(getGodotType (SimpleType (type: enumDef.name))): OptionSet") {
                p ("public let rawValue: Int")
                b ("public init (rawValue: Int)") {
                    p ("self.rawValue = rawValue")
                }
                for enumVal in enumDef.values {
                    let name = dropMatchingPrefix (enumDef.name, enumVal.name)
                    for d in constantDocs ?? [] {
                        if d.name == enumVal.name {
                            doc (cdef, d.value)
                            break
                        }
                    }
                    p ("public static let \(escapeSwift (name)) = \(enumDef.name) (rawValue: \(enumVal.value))")
                }
            }
            continue
        }
        var enumDefName = enumDef.name
        if enumDefName.starts(with: "Variant") {
            p ("extension Variant {")
            indent += 1
            enumDefName = String (enumDefName.dropFirst("Variant.".count))
        }
        b ("public enum \(getGodotType (SimpleType (type: enumDefName))): Int") {
            var used = Set<Int> ()
            
            for enumVal in enumDef.values {
                let enumValName = enumVal.name
                if enumDefName == "InlineAlignment" {
                    if enumValName == "INLINE_ALIGNMENT_TOP_TO" || enumValName == "INLINE_ALIGNMENT_TO_TOP" ||
                    enumValName == "INLINE_ALIGNMENT_IMAGE_MASK" || enumValName == "INLINE_ALIGNMENT_TEXT_MASK" {
                        continue
                    }
                }
                let name = dropMatchingPrefix (enumDefName, enumValName)
                let prefix: String
                if used.contains(enumVal.value) {
                    prefix = "// "
                } else {
                    prefix = ""
                }
                used.insert(enumVal.value)
                for d in constantDocs ?? [] {
                    if d.name == enumValName {
                        doc (cdef, d.rest)
                        break
                    }
                }
                p ("\(prefix)case \(escapeSwift(name)) = \(enumVal.value) // \(enumVal.name)")
            }
        }
        if enumDef.name.starts (with: "Variant") {
            indent -= 1
            p ("}\n")
        }
        if let prefix {
            globalEnums [prefix + enumDef.name] = enumDef
        }
    }
}


print ("Running with projectDir=$(projectDir) and output=\(outputDir)")
result = "// This file is autogenerated, do not edit\n"
result += "import Foundation\n@_implementationOnly import GDExtension\n\n"
let globalDocs = loadClassDoc(base: docRoot, name:  "@GlobalScope")
var classMap: [String:JGodotExtensionAPIClass] = [:]
for x in jsonApi.classes {
    classMap [x.name] = x
}

var builtinMap: [String: JGodotBuiltinClass] = [:]
generateEnums(cdef: nil, values: jsonApi.globalEnums, constantDocs: globalDocs?.constants?.constant, prefix: "")
for x in jsonApi.builtinClasses {
    let value = x.members?.count ?? 0 > 0
    isStructMap [String (x.name)] = value
    builtinMap [x.name] = x
}
for x in ["Float", "Int", "float", "int", "Variant", "Int32", "Bool", "bool"] {
    isStructMap [x] = true
}

var builtinSizes: [String: Int] = [:]
for cs in jsonApi.builtinClassSizes {
    if cs.buildConfiguration == "float_64" {
        for c in cs.sizes {
            builtinSizes [c.name] = c.size
        }
    }
}

let generatedBuiltinDir = outputDir + "/generated-builtin/"
let generatedDir = outputDir + "/generated/"

try! FileManager.default.createDirectory(atPath: generatedBuiltinDir, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(atPath: generatedDir, withIntermediateDirectories: true)

let coreDefs = result


generateBuiltinClasses(values: jsonApi.builtinClasses, outputDir: generatedBuiltinDir)

result = ""
generateClasses (values: jsonApi.classes, outputDir: generatedDir)

// Now go back and add the generated constructor pointers
result = coreDefs

p ("var godotFrameworkCtors = [")
for x in referenceTypes.keys {
    p ("    \"\(x)\": \(x).self, //(nativeHandle:),")
}
p ("]")
try! result.write(toFile: generatedBuiltinDir + "/core-defs.swift", atomically: true, encoding: .utf8)

print ("Done")
