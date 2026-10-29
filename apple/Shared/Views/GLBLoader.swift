import Foundation
import SceneKit

/// Minimal glTF 2.0 binary (.glb) loader for SceneKit: triangle meshes with positions, normals, UVs and
/// PBR materials (base color, normal and metallic-roughness textures). Enough for the racket model;
/// not a general-purpose importer (no skins, animations or node hierarchies beyond one level).
enum GLBLoader {
    struct LoadError: Error {}

    static func load(url: URL) throws -> SCNNode {
        let data = try Data(contentsOf: url)
        guard data.count > 20,
              data.prefix(4) == Data("glTF".utf8) else { throw LoadError() }
        let jsonLength = Int(data.u32(at: 12))
        let json = try JSONSerialization.jsonObject(with: data.subdata(in: 20..<(20 + jsonLength))) as? [String: Any] ?? [:]
        let binStart = 20 + jsonLength + 8
        let bin = data.subdata(in: binStart..<data.count)

        let accessors = json["accessors"] as? [[String: Any]] ?? []
        let bufferViews = json["bufferViews"] as? [[String: Any]] ?? []
        let images = json["images"] as? [[String: Any]] ?? []
        let textures = json["textures"] as? [[String: Any]] ?? []
        let materials = json["materials"] as? [[String: Any]] ?? []

        func viewData(_ index: Int) -> Data {
            let v = bufferViews[index]
            let offset = v["byteOffset"] as? Int ?? 0
            return bin.subdata(in: offset..<(offset + (v["byteLength"] as? Int ?? 0)))
        }

        func floats(_ accessorIndex: Int, components: Int) -> [Float] {
            let a = accessors[accessorIndex]
            let view = bufferViews[a["bufferView"] as? Int ?? 0]
            let base = (view["byteOffset"] as? Int ?? 0) + (a["byteOffset"] as? Int ?? 0)
            let stride = view["byteStride"] as? Int ?? components * 4
            let count = a["count"] as? Int ?? 0
            var out = [Float](repeating: 0, count: count * components)
            bin.withUnsafeBytes { raw in
                for i in 0..<count {
                    for c in 0..<components {
                        out[i * components + c] = raw.loadUnaligned(fromByteOffset: base + i * stride + c * 4, as: Float.self)
                    }
                }
            }
            return out
        }

        func indices(_ accessorIndex: Int) -> [UInt32] {
            let a = accessors[accessorIndex]
            let view = bufferViews[a["bufferView"] as? Int ?? 0]
            let base = (view["byteOffset"] as? Int ?? 0) + (a["byteOffset"] as? Int ?? 0)
            let count = a["count"] as? Int ?? 0
            let type = a["componentType"] as? Int ?? 5123
            return bin.withUnsafeBytes { raw in
                (0..<count).map { i in
                    switch type {
                    case 5121: return UInt32(raw.load(fromByteOffset: base + i, as: UInt8.self))
                    case 5125: return raw.loadUnaligned(fromByteOffset: base + i * 4, as: UInt32.self)
                    default: return UInt32(raw.loadUnaligned(fromByteOffset: base + i * 2, as: UInt16.self))
                    }
                }
            }
        }

        var imageCache: [Int: Any] = [:]
        func image(forTexture textureIndex: Int) -> Any? {
            guard textureIndex < textures.count, let source = textures[textureIndex]["source"] as? Int else { return nil }
            if let cached = imageCache[source] { return cached }
            guard source < images.count, let view = images[source]["bufferView"] as? Int else { return nil }
            let bytes = viewData(view)
            #if os(macOS)
            let img: Any? = NSImage(data: bytes)
            #else
            let img: Any? = UIImage(data: bytes)
            #endif
            imageCache[source] = img
            return img
        }

        func material(_ index: Int?) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            guard let index, index < materials.count else { return m }
            let spec = materials[index]
            m.name = spec["name"] as? String
            m.isDoubleSided = spec["doubleSided"] as? Bool ?? false
            let pbr = spec["pbrMetallicRoughness"] as? [String: Any] ?? [:]
            if let tex = (pbr["baseColorTexture"] as? [String: Any])?["index"] as? Int, let img = image(forTexture: tex) {
                m.diffuse.contents = img
            } else if let c = pbr["baseColorFactor"] as? [Double], c.count >= 3 {
                m.diffuse.contents = CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c.count > 3 ? c[3] : 1)
            }
            m.metalness.contents = (pbr["metallicFactor"] as? Double) ?? 1.0
            m.roughness.contents = (pbr["roughnessFactor"] as? Double) ?? 1.0
            if let tex = (pbr["metallicRoughnessTexture"] as? [String: Any])?["index"] as? Int, let img = image(forTexture: tex) {
                m.roughness.contents = img
                m.roughness.textureComponents = .green   // glTF packs roughness in G, metalness in B
            }
            if let tex = (spec["normalTexture"] as? [String: Any])?["index"] as? Int, let img = image(forTexture: tex) {
                m.normal.contents = img
            }
            return m
        }

        let root = SCNNode()
        for meshSpec in json["meshes"] as? [[String: Any]] ?? [] {
            for prim in meshSpec["primitives"] as? [[String: Any]] ?? [] {
                guard let attrs = prim["attributes"] as? [String: Int], let pos = attrs["POSITION"] else { continue }
                var sources: [SCNGeometrySource] = []
                let p = floats(pos, components: 3)
                sources.append(SCNGeometrySource(vertices: stride(from: 0, to: p.count, by: 3).map {
                    SCNVector3(p[$0], p[$0 + 1], p[$0 + 2])
                }))
                if let n = attrs["NORMAL"] {
                    let f = floats(n, components: 3)
                    sources.append(SCNGeometrySource(normals: stride(from: 0, to: f.count, by: 3).map {
                        SCNVector3(f[$0], f[$0 + 1], f[$0 + 2])
                    }))
                }
                if let t = attrs["TEXCOORD_0"] {
                    let f = floats(t, components: 2)
                    sources.append(SCNGeometrySource(textureCoordinates: stride(from: 0, to: f.count, by: 2).map {
                        CGPoint(x: CGFloat(f[$0]), y: CGFloat(f[$0 + 1]))
                    }))
                }
                guard let idx = prim["indices"] as? Int else { continue }
                let all = indices(idx)
                let base = material(prim["material"] as? Int)
                let geometry: SCNGeometry
                if base.name == "tennis racquet" {
                    // Split the handle off (butt is at z ≈ 4.4, grip ends near z ≈ 2) so it can take the secondary skin colour.
                    var frame: [UInt32] = [], grip: [UInt32] = []
                    for t in stride(from: 0, to: all.count - 2, by: 3) {
                        let z = (p[Int(all[t]) * 3 + 2] + p[Int(all[t + 1]) * 3 + 2] + p[Int(all[t + 2]) * 3 + 2]) / 3
                        if z > 2.0 { grip += all[t...t + 2] } else { frame += all[t...t + 2] }
                    }
                    geometry = SCNGeometry(sources: sources, elements: [
                        SCNGeometryElement(indices: frame, primitiveType: .triangles),
                        SCNGeometryElement(indices: grip, primitiveType: .triangles)])
                    let gripMaterial = base.copy() as! SCNMaterial
                    gripMaterial.name = "grip"
                    geometry.materials = [base, gripMaterial]
                } else {
                    geometry = SCNGeometry(sources: sources, elements: [SCNGeometryElement(indices: all, primitiveType: .triangles)])
                    geometry.materials = [base]
                }
                root.addChildNode(SCNNode(geometry: geometry))
            }
        }
        return root
    }
}

private extension Data {
    func u32(at offset: Int) -> UInt32 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }
}
