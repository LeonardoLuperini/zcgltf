const std = @import("std");
const assert = std.debug.assert;

const Alignment = std.mem.Alignment;
const MaxAlign = std.c.max_align_t;

comptime {
    assert(@sizeOf(usize) <= @sizeOf(MaxAlign));
}

/// This is NOT thread safe!

/// AllocTracker bridges Zig's allocator interface to cgltf's C callbacks.
///
/// cgltf lets you pass custom alloc/free functions plus a void* user_data
/// in Options.memory. We store a pointer to this struct as user_data, so
/// both callbacks can reach the backing Zig allocator without any global
/// state — each parseAndLoadFile call gets its own tracker.
///
/// The core trick is stolen from SDS: every allocation is oversized by
/// header_size bytes, the requested size is written at the front, and the
/// pointer returned to cgltf starts right after. On free we subtract
/// header_size to find the base and the stored length.
///
/// The tracker itself is heap-allocated by parseAndLoadFile so it outlives
/// the call — cgltf copies the user_data pointer into Data.memory and
/// uses it again when cgltf_free walks the tree. freeData extracts the
/// tracker, lets cgltf_free release everything, then destroys the tracker.
pub const AllocTracker = struct {
    backing_allocator: std.mem.Allocator,

    const header_size = @sizeOf(MaxAlign);
 
    pub fn init(allocator: std.mem.Allocator) AllocTracker {
        return .{
            .backing_allocator = allocator,
        };
    }
    /// Allocate memory for cgltf, storing the size in a header right before
    /// the returned pointer, similar to how SDS stores the string length
    /// before the char array. The layout in memory is:
    ///
    ///     [  size (usize)  |  padding  |  usable memory ... ]
    ///     ^                            ^
    ///     base pointer                 returned pointer
    ///
    /// The header is always @sizeOf(MaxAlign) bytes so that the returned
    /// pointer stays aligned to what C's malloc would guarantee. On free
    /// we just subtract the header size to recover both the base pointer
    /// and the original length — no hashmap needed.
    ///
    /// Returns null if the backing allocator fails or if the total size
    /// overflows. cgltf treats null as "out of memory" and propagates the
    /// error, so we don't need to panic here.
    pub fn allocFn(user: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
        const self: *AllocTracker = @ptrCast(@alignCast(user));

        const bytes = self.backing_allocator.alignedAlloc(
            u8,
            Alignment.fromByteUnits(header_size),
            header_size + size
            ) catch return null;

        const len: *usize = @ptrCast(@alignCast(bytes.ptr));
        len.* = size;

        return bytes[header_size..].ptr;
    }
 
    /// Inverse of allocFn. Given the pointer past the header that we returned
    /// to cgltf, we step back to recover the base pointer and the stored size,
    /// then free the whole allocation. Accepts null (C free semantics).
    pub fn freeFn(user: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void {
        const self: *AllocTracker = @ptrCast(@alignCast(user));
        const usable_ptr: [*]u8 = @ptrCast(ptr orelse return);

        // Step back past the header to the original allocation base.
        const base: [*]align(header_size) u8 = @ptrCast(@alignCast(usable_ptr - header_size));
        const stored_size = @as(*const usize, @ptrCast(base)).*;

        self.backing_allocator.free(base[0 .. header_size + stored_size]);
    }
};

const MallocFn = *const fn (user: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque;
const FreeFn = *const fn (user: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void;
 
pub const MemoryOptions = extern struct {
    alloc_func: ?MallocFn = null,
    free_func: ?FreeFn = null,
    user_data: ?*anyopaque = null,
};
 
pub const FileOptions = extern struct {
    const ReadFn = *const fn (
        memory_options: *const MemoryOptions,
        file_options: *const FileOptions,
        path: [*:0]const u8,
        size: *usize,
        data: *?*anyopaque
    ) callconv(.c) Result;

    const ReleaseFn = *const fn (
        memory_options: *const MemoryOptions,
        file_options: *const FileOptions,
        data: ?*anyopaque,
        size: usize
    ) callconv(.c) void;

    read: ?ReadFn = null,
    release: ?ReleaseFn = null,
    user_data: ?*anyopaque = null,
};

pub const Options = extern struct {
    type: FileType = .invalid,   // invalid -> auto detect
    json_token_count: usize = 0, // 0 -> auto
    memory: MemoryOptions = .{},
    file: FileOptions = .{},
};



// =============================================================================
// Public API
// =============================================================================
 
/// Parse and load a glTF file in one call. All memory is allocated through the
/// provided Zig allocator. Call `freeData` to release everything.
pub fn parseAndLoadFile(allocator: std.mem.Allocator, pathname: [:0]const u8) Error!*Data {
    // Heap-allocate the tracker so it outlives this call — cgltf stores
    // user_data inside Data.memory and uses it again in cgltf_free.
    const tracker = allocator.create(AllocTracker) catch return error.OutOfMemory;
    tracker.* = AllocTracker.init(allocator);
 
    const options = Options{
        .memory = .{
            .alloc_func = &AllocTracker.allocFn,
            .free_func = &AllocTracker.freeFn,
            .user_data = @ptrCast(tracker),
        },
    };
 
    const data = try parseFile(options, pathname);
    errdefer {
        cgltf_free(data);
        tracker.deinit();
        allocator.destroy(tracker);
    }
 
    try loadBuffers(options, data, pathname);
 
    return data;
}
 
/// Free all data allocated by `parseAndLoadFile`. Extracts the tracker from
/// the stored memory options, so no allocator argument is needed.
pub fn freeData(data: *Data) void {
    const tracker: *AllocTracker = @ptrCast(@alignCast(data.memory.user_data));
    const allocator = tracker.backing_allocator;
 
    cgltf_free(data); // calls freeFn for every cgltf allocation
    allocator.destroy(tracker); // frees the tracker struct itself
}
 
// Lower-level API for advanced usage (bring your own Options).
 
pub fn parseFile(options: Options, path: [*:0]const u8) Error!*Data {
    var out_data: ?*Data = null;
    const result = cgltf_parse_file(&options, path, &out_data);
    try resultToError(result);
    return out_data.?;
}
 
pub fn loadBuffers(options: Options, data: *Data, gltf_path: [*:0]const u8) Error!void {
    const result = cgltf_load_buffers(&options, data, gltf_path);
    try resultToError(result);
}
 
pub fn free(data: *Data) void {
    cgltf_free(data);
}

// =============================================================================
// Error handling
// =============================================================================
 
pub const Error = error{
    DataTooShort,
    UnknownFormat,
    InvalidJson,
    InvalidGltf,
    InvalidOptions,
    FileNotFound,
    IoError,
    OutOfMemory,
    LegacyGltf,
};
 
fn resultToError(result: Result) Error!void {
    switch (result) {
        .success         => return,
        .data_too_short  => return error.DataTooShort,
        .unknown_format  => return error.UnknownFormat,
        .invalid_json    => return error.InvalidJson,
        .invalid_gltf    => return error.InvalidGltf,
        .invalid_options => return error.InvalidOptions,
        .file_not_found  => return error.FileNotFound,
        .io_error        => return error.IoError,
        .out_of_memory   => return error.OutOfMemory,
        .legacy_gltf     => return error.LegacyGltf,
    }
}

// =============================================================================
// Primitive types
// =============================================================================
 
pub const Bool32 = i32;
pub const CString = [*:0]const u8;
pub const MutCString = [*:0]u8;
 
// =============================================================================
// Enums
// =============================================================================
 
pub const FileType = enum(c_int) {
    invalid,
    gltf,
    glb,
};
 
pub const Result = enum(c_int) {
    success,
    data_too_short,
    unknown_format,
    invalid_json,
    invalid_gltf,
    invalid_options,
    file_not_found,
    io_error,
    out_of_memory,
    legacy_gltf,
};
 
pub const BufferViewType = enum(c_int) {
    invalid,
    indices,
    vertices,
};
 
pub const AttributeType = enum(c_int) {
    invalid,
    position,
    normal,
    tangent,
    texcoord,
    color,
    joints,
    weights,
    custom,
};
 
pub const ComponentType = enum(c_int) {
    invalid,
    r_8,
    r_8u,
    r_16,
    r_16u,
    r_32u,
    r_32f,
};
 
pub const Type = enum(c_int) {
    invalid,
    scalar,
    vec2,
    vec3,
    vec4,
    mat2,
    mat3,
    mat4,
 
    pub fn numComponents(dtype: Type) usize {
        return switch (dtype) {
            .vec2 => 2,
            .vec3 => 3,
            .vec4 => 4,
            .mat2 => 4,
            .mat3 => 9,
            .mat4 => 16,
            else => 1,
        };
    }
};
 
pub const PrimitiveType = enum(c_int) {
    invalid,
    points,
    lines,
    line_loop,
    line_strip,
    triangles,
    triangle_strip,
    triangle_fan,
};
 
pub const AlphaMode = enum(c_int) {
    @"opaque",
    mask,
    blend,
};
 
pub const AnimationPathType = enum(c_int) {
    invalid,
    translation,
    rotation,
    scale,
    weights,
};
 
pub const InterpolationType = enum(c_int) {
    linear,
    step,
    cubic_spline,
};
 
pub const CameraType = enum(c_int) {
    invalid,
    perspective,
    orthographic,
};
 
pub const LightType = enum(c_int) {
    invalid,
    directional,
    point,
    spot,
};
 
pub const DataFreeMethod = enum(c_int) {
    none,
    file_release,
    memory_free,
};
 
pub const MeshoptCompressionMode = enum(c_int) {
    invalid,
    attributes,
    triangles,
    indices,
};
 
pub const MeshoptCompressionFilter = enum(c_int) {
    none,
    octahedral,
    quaternion,
    exponential,
};
 
// =============================================================================
// Options
// =============================================================================
 

 
// =============================================================================
// Data structures — extern structs matching cgltf's C layout.
// =============================================================================
 
pub const Extras = extern struct {
    start_offset: usize,
    end_offset: usize,
    data: ?[*]u8,
};
 
pub const Extension = extern struct {
    name: ?MutCString,
    data: ?MutCString,
};
 
pub const Buffer = extern struct {
    name: ?MutCString,
    size: usize,
    uri: ?MutCString,
    data: ?*anyopaque,
    data_free_method: DataFreeMethod,
    extras: Extras,
    extensions_count: usize,
    extensions: ?[*]Extension,
};
 
pub const MeshoptCompression = extern struct {
    buffer: *Buffer,
    offset: usize,
    size: usize,
    stride: usize,
    count: usize,
    mode: MeshoptCompressionMode,
    filter: MeshoptCompressionFilter,
};
 
pub const BufferView = extern struct {
    name: ?MutCString,
    buffer: *Buffer,
    offset: usize,
    size: usize,
    stride: usize,
    view_type: BufferViewType,
    data: ?*anyopaque,
    has_meshopt_compression: Bool32,
    meshopt_compression: MeshoptCompression,
    extras: Extras,
    extensions_count: usize,
    extensions: ?[*]Extension,
};
 
pub const AccessorSparse = extern struct {
    count: usize,
    indices_buffer_view: *BufferView,
    indices_byte_offset: usize,
    indices_component_type: ComponentType,
    values_buffer_view: *BufferView,
    values_byte_offset: usize,
};
 
pub const Accessor = extern struct {
    name: ?MutCString,
    component_type: ComponentType,
    normalized: Bool32,
    type: Type,
    offset: usize,
    count: usize,
    stride: usize,
    buffer_view: ?*BufferView,
    has_min: Bool32,
    min: [16]f32,
    has_max: Bool32,
    max: [16]f32,
    is_sparse: Bool32,
    sparse: AccessorSparse,
    extras: Extras,
    extensions_count: usize,
    extensions: ?[*]Extension,
};
 
pub const Attribute = extern struct {
    name: ?MutCString,
    type: AttributeType,
    index: i32,
    data: *Accessor,
};
 
pub const Image = extern struct {
    name: ?MutCString,
    uri: ?MutCString,
    buffer_view: ?*BufferView,
    mime_type: ?MutCString,
    extras: Extras,
    extensions_count: usize,
    extensions: ?[*]Extension,
};
 
pub const FilterType = enum(c_int) {
    undefined = 0,
    nearest = 9728,
    linear = 9729,
    nearest_mipmap_nearest = 9984,
    linear_mipmap_nearest = 9985,
    nearest_mipmap_linear = 9986,
    linear_mipmap_linear = 9987,
};
 
pub const WrapMode = enum(c_int) {
    clamp_to_edge = 33071,
    mirrored_repeat = 33648,
    repeat = 10497,
};
 
pub const Sampler = extern struct {
    uri: ?MutCString,
    mag_filter: FilterType,
    min_filter: FilterType,
    wrap_s: WrapMode,
    wrap_t: WrapMode,
    extras: Extras,
    extensions_count: usize,
    extensions: ?[*]Extension,
};
 
pub const Texture = extern struct {
    name: ?MutCString,
    image: ?*Image,
    sampler: ?*Sampler,
    has_basisu: Bool32,
    basisu_image: ?*Image,
    has_webp: Bool32,
    webp_image: ?*Image,
    extras: Extras,
    extensions_count: usize,
    extensions: ?[*]Extension,
};
 
pub const TextureTransform = extern struct {
    offset: [2]f32,
    rotation: f32,
    scale: [2]f32,
    has_texcoord: Bool32,
    texcoord: i32,
};
 
pub const TextureView = extern struct {
    texture: ?*Texture,
    texcoord: i32,
    scale: f32,
    has_transform: Bool32,
    transform: TextureTransform,
};
 
pub const PbrMetallicRoughness = extern struct {
    base_color_texture: TextureView,
    metallic_roughness_texture: TextureView,
    base_color_factor: [4]f32,
    metallic_factor: f32,
    roughness_factor: f32,
};
 
pub const PbrSpecularGlossiness = extern struct {
    diffuse_texture: TextureView,
    specular_glossiness_texture: TextureView,
    diffuse_factor: [4]f32,
    specular_factor: [3]f32,
    glossiness_factor: f32,
};
 
pub const Clearcoat = extern struct {
    clearcoat_texture: TextureView,
    clearcoat_roughness_texture: TextureView,
    clearcoat_normal_texture: TextureView,
    clearcoat_factor: f32,
    clearcoat_roughness_factor: f32,
};
 
pub const Transmission = extern struct {
    transmission_texture: TextureView,
    transmission_factor: f32,
};
 
pub const Ior = extern struct {
    ior: f32,
};
 
pub const Specular = extern struct {
    specular_texture: TextureView,
    specular_color_texture: TextureView,
    specular_color_factor: [3]f32,
    specular_factor: f32,
};
 
pub const Volume = extern struct {
    thickness_texture: TextureView,
    thickness_factor: f32,
    attentuation_color: [3]f32,
    attentuation_distance: f32,
};
 
pub const Sheen = extern struct {
    sheen_color_texture: TextureView,
    sheen_color_factor: [3]f32,
    sheen_roughness_texture: TextureView,
    sheen_roughness_factor: f32,
};
 
pub const EmissiveStrength = extern struct {
    emissive_strength: f32,
};
 
pub const Iridescence = extern struct {
    iridescence_factor: f32,
    iridescence_texture: TextureView,
    iridescence_ior: f32,
    iridescence_thickness_min: f32,
    iridescence_thickness_max: f32,
    iridescence_thickness_texture: TextureView,
};
 
pub const DiffuseTransmission = extern struct {
    diffuse_transmission_texture: TextureView,
    diffuse_transmission_factor: f32,
    diffuse_transmission_color_factor: [3]f32,
    diffuse_transmission_color_texture: TextureView,
};
 
pub const Anisotropy = extern struct {
    anisotropy_strength: f32,
    anisotropy_rotation: f32,
    anisotropy_texture: TextureView,
};
 
pub const Dispersion = extern struct {
    dispersion: f32,
};
 
pub const Material = extern struct {
    name: ?MutCString,
    has_pbr_metallic_roughness: Bool32,
    has_pbr_specular_glossiness: Bool32,
    has_clearcoat: Bool32,
    has_transmission: Bool32,
    has_volume: Bool32,
    has_ior: Bool32,
    has_specular: Bool32,
    has_sheen: Bool32,
    has_emissive_strength: Bool32,
    has_iridescence: Bool32,
    has_diffuse_transmission: Bool32,
    has_anisotropy: Bool32,
    has_dispersion: Bool32,
    pbr_metallic_roughness: PbrMetallicRoughness,
    pbr_specular_glossiness: PbrSpecularGlossiness,
    clearcoat: Clearcoat,
    ior: Ior,
    specular: Specular,
    sheen: Sheen,
    transmission: Transmission,
    volume: Volume,
    emissive_strength: EmissiveStrength,
    iridescence: Iridescence,
    diffuse_transmission: DiffuseTransmission,
    anisotropy: Anisotropy,
    dispersion: Dispersion,
    normal_texture: TextureView,
    occlusion_texture: TextureView,
    emissive_texture: TextureView,
    emissive_factor: [3]f32,
    alpha_mode: AlphaMode,
    alpha_cutoff: f32,
    double_sided: Bool32,
    unlit: Bool32,
    extras: Extras,
    extensions_count: usize,
    extensions: ?[*]Extension,
};
 
pub const MaterialMapping = extern struct {
    variant: usize,
    material: ?*Material,
    extras: Extras,
};
 
pub const MorphTarget = extern struct {
    attributes: ?[*]Attribute,
    attributes_count: usize,
};
 
pub const DracoMeshCompression = extern struct {
    buffer_view: ?*BufferView,
    attributes: ?[*]Attribute,
    attributes_count: usize,
};
 
pub const MeshGpuInstancing = extern struct {
    attributes: ?[*]Attribute,
    attributes_count: usize,
};
 
pub const Primitive = extern struct {
    type: PrimitiveType,
    indices: ?*Accessor,
    material: ?*Material,
    attributes: [*]Attribute,
    attributes_count: usize,
    targets: ?[*]MorphTarget,
    targets_count: usize,
    extras: Extras,
    has_draco_mesh_compression: Bool32,
    draco_mesh_compression: DracoMeshCompression,
    mappings: ?[*]MaterialMapping,
    mappings_count: usize,
    extensions_count: usize,
    extensions: ?[*]Extension,
};
 
pub const Mesh = extern struct {
    name: ?MutCString,
    primitives: [*]Primitive,
    primitives_count: usize,
    weights: ?[*]f32,
    weights_count: usize,
    target_names: ?[*]MutCString,
    target_names_count: usize,
    extras: Extras,
    extensions_count: usize,
    extensions: ?[*]Extension,
};
 
pub const Skin = extern struct {
    name: ?MutCString,
    joints: [*]*Node,
    joints_count: usize,
    skeleton: ?*Node,
    inverse_bind_matrices: ?*Accessor,
    extras: Extras,
    extensions_count: usize,
    extensions: ?[*]Extension,
};
 
pub const CameraPerspective = extern struct {
    has_aspect_ratio: Bool32,
    aspect_ratio: f32,
    yfov: f32,
    has_zfar: Bool32,
    zfar: f32,
    znear: f32,
    extras: Extras,
};
 
pub const CameraOrthographic = extern struct {
    xmag: f32,
    ymag: f32,
    zfar: f32,
    znear: f32,
    extras: Extras,
};
 
pub const Camera = extern struct {
    name: ?MutCString,
    type: CameraType,
    data: extern union {
        perspective: CameraPerspective,
        orthographic: CameraOrthographic,
    },
    extras: Extras,
    extensions_count: usize,
    extensions: ?[*]Extension,
};
 
pub const Light = extern struct {
    name: ?MutCString,
    color: [3]f32,
    intensity: f32,
    type: LightType,
    range: f32,
    spot_inner_cone_angle: f32,
    spot_outer_cone_angle: f32,
    extras: Extras,
};
 
pub const Node = extern struct {
    name: ?MutCString,
    parent: ?*Node,
    children: ?[*]*Node,
    children_count: usize,
    skin: ?*Skin,
    mesh: ?*Mesh,
    camera: ?*Camera,
    light: ?*Light,
    weights: [*]f32,
    weights_count: usize,
    has_translation: Bool32,
    has_rotation: Bool32,
    has_scale: Bool32,
    has_matrix: Bool32,
    translation: [3]f32,
    rotation: [4]f32,
    scale: [3]f32,
    matrix: [16]f32,
    extras: Extras,
    has_mesh_gpu_instancing: Bool32,
    mesh_gpu_instancing: MeshGpuInstancing,
    extensions_count: usize,
    extensions: ?[*]Extension,
};
 
pub const Scene = extern struct {
    name: ?MutCString,
    nodes: ?[*]*Node,
    nodes_count: usize,
    extras: Extras,
    extensions_count: usize,
    extensions: ?[*]Extension,
};
 
pub const AnimationSampler = extern struct {
    input: *Accessor,
    output: *Accessor,
    interpolation: InterpolationType,
    extras: Extras,
    extensions_count: usize,
    extensions: ?[*]Extension,
};
 
pub const AnimationChannel = extern struct {
    sampler: *AnimationSampler,
    target_node: ?*Node,
    target_path: AnimationPathType,
    extras: Extras,
    extensions_count: usize,
    extensions: ?[*]Extension,
};
 
pub const Animation = extern struct {
    name: ?MutCString,
    samplers: [*]AnimationSampler,
    samplers_count: usize,
    channels: [*]AnimationChannel,
    channels_count: usize,
    extras: Extras,
    extensions_count: usize,
    extensions: ?[*]Extension,
};
 
pub const MaterialVariant = extern struct {
    name: ?MutCString,
    extras: Extras,
};
 
pub const Asset = extern struct {
    copyright: ?MutCString,
    generator: ?MutCString,
    version: ?MutCString,
    min_version: ?MutCString,
    extras: Extras,
    extensions_count: usize,
    extensions: ?[*]Extension,
};
 
pub const Data = extern struct {
    file_type: FileType,
    file_data: ?*anyopaque,
 
    asset: Asset,
 
    meshes: ?[*]Mesh,
    meshes_count: usize,
 
    materials: ?[*]Material,
    materials_count: usize,
 
    accessors: ?[*]Accessor,
    accessors_count: usize,
 
    buffer_views: ?[*]BufferView,
    buffer_views_count: usize,
 
    buffers: ?[*]Buffer,
    buffers_count: usize,
 
    images: ?[*]Image,
    images_count: usize,
 
    textures: ?[*]Texture,
    textures_count: usize,
 
    samplers: ?[*]Sampler,
    samplers_count: usize,
 
    skins: ?[*]Skin,
    skins_count: usize,
 
    cameras: ?[*]Camera,
    cameras_count: usize,
 
    lights: ?[*]Light,
    lights_count: usize,
 
    nodes: ?[*]Node,
    nodes_count: usize,
 
    scenes: ?[*]Scene,
    scenes_count: usize,
 
    scene: ?*Scene,
 
    animations: ?[*]Animation,
    animations_count: usize,
 
    variants: ?[*]MaterialVariant,
    variants_count: usize,
 
    extras: Extras,
 
    data_extensions_count: usize,
    data_extensions: ?[*]Extension,
 
    extensions_used: ?[*]MutCString,
    extensions_used_count: usize,
 
    extensions_required: ?[*]MutCString,
    extensions_required_count: usize,
 
    json: ?CString,
    json_size: usize,
 
    bin: ?*const anyopaque,
    bin_size: usize,
 
    memory: MemoryOptions,
    file: FileOptions,
};
 
// =============================================================================
// C extern declarations
// =============================================================================
extern fn cgltf_parse_file(options: *const Options, path: [*:0]const u8, data: *?*Data) Result;

extern fn cgltf_load_buffers(options: *const Options, data: *Data, path: [*:0]const u8) Result;

extern fn cgltf_free(data: *Data) void;
 
extern fn cgltf_validate(data: ?*Data) Result;

// =============================================================================
// Tests
// =============================================================================
 
test {
    std.testing.refAllDeclsRecursive(@This());
}
