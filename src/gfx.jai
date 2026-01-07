/* Renderer */

Camera_2D :: struct {
    target: Vector2;     // Camera target (world space point to map to the origin; what we're looking at in world space)
    offset: Vector2;     // Camera offset (window origin in screen space; or displacement from target in screen space)
    rotation: float;     // Camera rotation in degrees
    zoom: float = 1.0;   // Zoom level (1.0 = normal, 2.0 = zoomed in 2x)
}

create_camera :: () -> Camera_2D {
    camera: Camera_2D;
    camera.target = .{0, 0};
    camera.offset = .{0, 0};
    camera.rotation = 0;
    camera.zoom = 1.0;
    return camera;
}

get_view_matrix :: (camera: *Camera_2D) -> Matrix4 {
    // 1. Translate by -target (move world so target is at origin)
    // 2. Rotate
    // 3. Scale by zoom
    // 4. Translate by offset (move to screen position)

    mat_origin := make_translation_matrix4({-camera.target.x, -camera.target.y, 0});

    // Rotation in degrees, convert to radians
    angle_rad := camera.rotation * (PI / 180.0);
    mat_rotation := make_rotation_matrix4_2d(angle_rad);

    mat_scale := make_scale_matrix4({camera.zoom, camera.zoom, 1.0});
    mat_translation := make_translation_matrix4({camera.offset.x, camera.offset.y, 0});

    // Combine: offset * scale * rotation * (-target)
    return mat_translation * mat_scale * mat_rotation * mat_origin;
}

UBO :: struct {
    mvp: Matrix4;
}

Vertex_Data :: struct {
    position: Vector3;
    color:    Vector4;
    uv:       Vector2;
}

Texture :: struct {
    gpu_texture: *sdl.GPU_Texture;
    width: s32;
    height: s32;
}

Draw_Call :: struct {
    texture: *Texture;
    vertex_offset: u32;
    vertex_count: u32;
    index_offset: u32;
    index_count: u32;
}

Line_Draw_Call :: struct {
    vertex_offset: u32;
    vertex_count: u32;
}

Renderer :: struct {
    device: *sdl.GPU_Device;
    window: *sdl.Window;
    camera: *Camera_2D; // Set when calling begin_camera_mode

    viewport: sdl.GPU_Viewport;
    target_width: s32 = 640;
    target_height: s32 = 360;
    use_viewport: bool = true;

    current_render_pass: *sdl.GPU_Render_Pass;
    current_cmd: *sdl.GPU_Command_Buffer;
    swapchain_texture: *sdl.GPU_Texture;
    white_texture: *Texture;

    quad_pipeline: *sdl.GPU_Graphics_Pipeline;
    line_pipeline: *sdl.GPU_Graphics_Pipeline;
    sampler: *sdl.GPU_Sampler;

    quad_vertex_buffer: *sdl.GPU_Buffer;
    quad_index_buffer: *sdl.GPU_Buffer;
    quad_transfer_buffer: *sdl.GPU_Transfer_Buffer;

    line_vertex_buffer: *sdl.GPU_Buffer;
    line_transfer_buffer: *sdl.GPU_Transfer_Buffer;

    /* Frame-wide accumulation (no mid-frame flushing) */
    frame_quad_vertices: [..]Vertex_Data;
    frame_quad_indices: [..]u16;
    frame_draws: [..]Draw_Call;
    frame_line_vertices: [..]Vertex_Data;
    frame_line_draws: [..]Line_Draw_Call;

    max_vertices: int;
    max_indices: int;
    max_line_vertices: int;

    projection: Matrix4;
}

renderer_init :: (width: s32, height: s32, title: string, use_viewport := true) -> Renderer, bool {
    renderer: Renderer;
    renderer.use_viewport = use_viewport;

    if !sdl.init(sdl.Init_Flags.VIDEO) {
        log_error("Could not initialize SDL: %\n", to_string(sdl.get_error()));
        return renderer, false;
    }

    renderer.device = sdl.create_gpu_device(
        sdl.GPU_Shader_Format.SPIRV | sdl.GPU_Shader_Format.DXIL | sdl.GPU_Shader_Format.MSL,
        true, null
    );
    if !renderer.device {
        log_error("SDL_CreateDevice failed: %\n", to_string(sdl.get_error()));
        return renderer, false;
    }

    renderer.window = sdl.create_window(title.data, width, height, sdl.Window_Flags.RESIZABLE);
    if !renderer.window {
        log_error("Could not create window: %\n", to_string(sdl.get_error()));
        return renderer, false;
    }

    if !sdl.claim_window_for_gpu_device(renderer.device, renderer.window) {
        log_error("SDL_ClaimWindowForGPUDevice failed: %\n", to_string(sdl.get_error()));
        return renderer, false;
    }

    // Load shaders
    vertex_shader := load_shader(renderer.device, "assets/shaders/basic2d.vert", 0, 1, 0, 0);
    if !vertex_shader {
        log_error("Failed to create vertex shader\n");
        return renderer, false;
    }
    defer sdl.release_gpu_shader(renderer.device, vertex_shader);

    fragment_shader := load_shader(renderer.device, "assets/shaders/basic2d.frag", 1, 0, 0, 0);
    if !fragment_shader {
        log_error("Failed to create fragment shader\n");
        return renderer, false;
    }
    defer sdl.release_gpu_shader(renderer.device, fragment_shader);

    // Setup vertex input
    vertex_buffer_desc: sdl.GPU_Vertex_Buffer_Description;
    vertex_buffer_desc.pitch = size_of(Vertex_Data);
    vertex_buffer_desc.input_rate = .VERTEX;

    vertex_attributes: [3]sdl.GPU_Vertex_Attribute = .[
        {location = 0, buffer_slot = 0, format = .FLOAT3, offset = 0},
        {location = 1, buffer_slot = 0, format = .FLOAT4, offset = size_of(Vector3)},
        {location = 2, buffer_slot = 0, format = .FLOAT2, offset = size_of(Vector3) + size_of(Vector4)}
    ];

    vertex_input_state: sdl.GPU_Vertex_Input_State;
    vertex_input_state.num_vertex_buffers = 1;
    vertex_input_state.vertex_buffer_descriptions = *vertex_buffer_desc;
    vertex_input_state.num_vertex_attributes = vertex_attributes.count;
    vertex_input_state.vertex_attributes = vertex_attributes.data;

    // Create pipelines
    renderer.quad_pipeline = create_pipeline(renderer.device, renderer.window, vertex_shader, fragment_shader, vertex_input_state, .TRIANGLELIST, enable_blend=true);
    if !renderer.quad_pipeline {
        log_error("Failed to create triangle pipeline\n");
        return renderer, false;
    }

    renderer.line_pipeline = create_pipeline(renderer.device, renderer.window, vertex_shader, fragment_shader, vertex_input_state, .LINELIST);
    if !renderer.line_pipeline {
        log_error("Failed to create line pipeline\n");
        return renderer, false;
    }

    renderer.sampler = create_sampler(renderer.device);
    renderer.max_vertices = 4000;     // 1000 quads * 4 vertices
    renderer.max_indices = 6000;      // 1000 quads * 6 indices
    renderer.max_line_vertices = 2000; // 1000 lines * 2 vertices

    // Create buffers
    renderer.quad_vertex_buffer = create_gpu_buffer(renderer.device, .VERTEX, cast(u32)(size_of(Vertex_Data) * renderer.max_vertices), "Vertex Buffer");
    renderer.quad_index_buffer = create_gpu_buffer(renderer.device, .INDEX, cast(u32)(size_of(u16) * renderer.max_indices), "Index Buffer");
    renderer.line_vertex_buffer = create_gpu_buffer(renderer.device, .VERTEX, cast(u32)(size_of(Vertex_Data) * renderer.max_line_vertices), "Line Vertex Buffer");

    quad_transfer_buffer_info: sdl.GPU_Transfer_Buffer_Create_Info;
    quad_transfer_buffer_info.usage = .UPLOAD;
    quad_transfer_buffer_info.size = cast(u32)(size_of(Vertex_Data) * renderer.max_vertices + size_of(u16) * renderer.max_indices);
    renderer.quad_transfer_buffer = sdl.create_gpu_transfer_buffer(renderer.device, *quad_transfer_buffer_info);

    line_transfer_buffer_info: sdl.GPU_Transfer_Buffer_Create_Info;
    line_transfer_buffer_info.usage = .UPLOAD;
    line_transfer_buffer_info.size = cast(u32)(size_of(Vertex_Data) * renderer.max_line_vertices);
    renderer.line_transfer_buffer = sdl.create_gpu_transfer_buffer(renderer.device, *line_transfer_buffer_info);

    // Setup projection
    drawable_width, drawable_height: s32;
    sdl.get_window_size_in_pixels(renderer.window, *drawable_width, *drawable_height);
    if renderer.use_viewport {
        set_viewport(*renderer, drawable_width, drawable_height);
        renderer.projection = orthographic_projection_matrix(
            left = 0,
            right = cast(float)renderer.target_width,
            bottom = cast(float)renderer.target_height,
            top = 0,
            near = 0,
            far = 1,
        );
    } else {
        renderer.projection = orthographic_projection_matrix(
            left = 0,
            right = drawable_width.(float),
            bottom = drawable_height.(float),
            top = 0,
            near = 0,
            far = 1,
        );
    }

    // Create white texture
    renderer.white_texture = create_white_texture(*renderer);
    if renderer.white_texture == null {
        log_error("Failed to create white texture for renderer: %\n", to_string(sdl.get_error()));
        return renderer, false;
    }

    return renderer, true;
}

renderer_shutdown :: (renderer: *Renderer) {
    sdl.release_gpu_transfer_buffer(renderer.device, renderer.quad_transfer_buffer);
    sdl.release_gpu_transfer_buffer(renderer.device, renderer.line_transfer_buffer);
    sdl.release_gpu_buffer(renderer.device, renderer.quad_vertex_buffer);
    sdl.release_gpu_buffer(renderer.device, renderer.quad_index_buffer);
    sdl.release_gpu_buffer(renderer.device, renderer.line_vertex_buffer);
    sdl.release_gpu_graphics_pipeline(renderer.device, renderer.quad_pipeline);
    sdl.release_gpu_graphics_pipeline(renderer.device, renderer.line_pipeline);
    sdl.release_gpu_sampler(renderer.device, renderer.sampler);
    sdl.destroy_gpu_device(renderer.device);
    sdl.destroy_window(renderer.window);
    sdl.quit();
}

create_pipeline :: (
    device: *sdl.GPU_Device,
    window: *sdl.Window,
    vertex_shader: *sdl.GPU_Shader,
    fragment_shader: *sdl.GPU_Shader,
    vertex_input_state: sdl.GPU_Vertex_Input_State,
    primitive_type: sdl.GPU_Primitive_Type,
    enable_blend: bool = false
) -> *sdl.GPU_Graphics_Pipeline {
    swapchain_format: sdl.GPU_Texture_Format = sdl.get_gpu_swapchain_texture_format(device, window);
    color_target: sdl.GPU_Color_Target_Description;
    color_target.format = swapchain_format;
    if enable_blend {
        blend_state: sdl.GPU_Color_Target_Blend_State;
        blend_state.enable_blend = true;
        blend_state.src_color_blendfactor = .SRC_ALPHA;
        blend_state.dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA;
        blend_state.color_blend_op = .ADD;
        blend_state.src_alpha_blendfactor = .ONE;
        blend_state.dst_alpha_blendfactor = .ONE_MINUS_SRC_ALPHA;
        blend_state.alpha_blend_op = .ADD;
        color_target.blend_state = blend_state;
    }

    pipeline_info: sdl.GPU_Graphics_Pipeline_Create_Info;
    pipeline_info.vertex_shader = vertex_shader;
    pipeline_info.fragment_shader = fragment_shader;
    pipeline_info.vertex_input_state = vertex_input_state;
    pipeline_info.primitive_type = primitive_type;
    pipeline_info.target_info.num_color_targets = 1;
    pipeline_info.target_info.color_target_descriptions = *color_target;

    return sdl.create_gpu_graphics_pipeline(device, *pipeline_info);
}

create_sampler :: (
    device: *sdl.GPU_Device,
    min_filter: sdl.GPU_Filter = .NEAREST,
    mag_filter: sdl.GPU_Filter = .NEAREST,
    mipmap_mode: sdl.GPU_Sampler_Mipmap_Mode = .NEAREST,
    address_mode_u: sdl.GPU_Sampler_Address_Mode = .CLAMP_TO_EDGE,
    address_mode_v: sdl.GPU_Sampler_Address_Mode = .CLAMP_TO_EDGE,
    address_mode_w: sdl.GPU_Sampler_Address_Mode = .CLAMP_TO_EDGE
) -> *sdl.GPU_Sampler {
    info: sdl.GPU_Sampler_Create_Info;
    info.min_filter = min_filter;
    info.mag_filter = mag_filter;
    info.mipmap_mode = mipmap_mode;
    info.address_mode_u = address_mode_u;
    info.address_mode_v = address_mode_v;
    info.address_mode_w = address_mode_w;

    return sdl.create_gpu_sampler(device, *info);
}

create_gpu_buffer :: (device: *sdl.GPU_Device, usage: sdl.GPU_Buffer_Usage_Flags, size: u32, name: string = "") -> *sdl.GPU_Buffer {
    info: sdl.GPU_Buffer_Create_Info;
    info.usage = usage;
    info.size = size;
    buffer: *sdl.GPU_Buffer = sdl.create_gpu_buffer(device, *info);

    if name && buffer sdl.set_gpu_buffer_name(device, buffer, name.data);

    return buffer;
}

create_gpu_texture :: (device: *sdl.GPU_Device, w: u32, h: u32, format: sdl.GPU_Texture_Format, name: string = "") -> *sdl.GPU_Texture {
    info: sdl.GPU_Texture_Create_Info;
    info.type = .TYPE_2D;
    info.format = format;
    info.width = w;
    info.height = h;
    info.layer_count_or_depth = 1;
    info.num_levels = 1;
    info.usage = .SAMPLER;
    texture: *sdl.GPU_Texture = sdl.create_gpu_texture(device, *info);

    if name && texture sdl.set_gpu_texture_name(device, texture, name.data);

    return texture;
}

create_white_texture :: (renderer: *Renderer) -> *Texture {
    white_surface := sdl.create_surface(1, 1, .RGBA32);
    if !white_surface {
        log_error("Failed to create white surface\n");
        return null;
    }
    defer sdl.destroy_surface(white_surface);

    white_pixels := cast(*u32)white_surface.pixels;
    white_pixels[0] = 0xFFFFFFFF;

    texture := New(Texture);
    texture.width = 1;
    texture.height = 1;
    texture.gpu_texture = create_gpu_texture(renderer.device, 1, 1, .R8G8B8A8_UNORM, "White Texture");

    texture_transfer_info: sdl.GPU_Transfer_Buffer_Create_Info;
    texture_transfer_info.usage = .UPLOAD;
    texture_transfer_info.size = 4;
    white_transfer := sdl.create_gpu_transfer_buffer(renderer.device, *texture_transfer_info);
    if !white_transfer {
        log_error("Failed to create transfer buffer for white texture\n");
        return null;
    }

    white_ptr := cast(*u8)sdl.map_gpu_transfer_buffer(renderer.device, white_transfer, false);
    memcpy(white_ptr, white_surface.pixels, 4);
    sdl.unmap_gpu_transfer_buffer(renderer.device, white_transfer);

    cmd := sdl.acquire_gpu_command_buffer(renderer.device);
    copy_pass := sdl.begin_gpu_copy_pass(cmd);

    tex_transfer: sdl.GPU_Texture_Transfer_Info;
    tex_transfer.transfer_buffer = white_transfer;
    tex_region: sdl.GPU_Texture_Region;
    tex_region.texture = texture.gpu_texture;
    tex_region.w = 1;
    tex_region.h = 1;
    tex_region.d = 1;
    sdl.upload_to_gpu_texture(copy_pass, *tex_transfer, *tex_region, false);

    sdl.end_gpu_copy_pass(copy_pass);
    sdl.submit_gpu_command_buffer(cmd);
    sdl.release_gpu_transfer_buffer(renderer.device, white_transfer);

    return texture;
}

begin_frame :: (renderer: *Renderer) -> bool {
    time_begin_frame();

    renderer.current_cmd = sdl.acquire_gpu_command_buffer(renderer.device);
    if !renderer.current_cmd {
        log_error("SDL_AcquireGPUCommandBuffer failed: %\n", to_string(sdl.get_error()));
        return false;
    }

    acquired := sdl.wait_and_acquire_gpu_swapchain_texture(renderer.current_cmd, renderer.window, *renderer.swapchain_texture, null, null);
    if !acquired || !renderer.swapchain_texture return false;

    color_target: sdl.GPU_Color_Target_Info;
    color_target.texture = renderer.swapchain_texture;
    color_target.clear_color = .{0.3, 0.6, 0.5, 1.0};
    color_target.load_op = .CLEAR;
    color_target.store_op = .STORE;

    renderer.current_render_pass = sdl.begin_gpu_render_pass(renderer.current_cmd, *color_target, 1, null);
    if renderer.use_viewport then sdl.set_gpu_viewport(renderer.current_render_pass, *renderer.viewport);

    return true;
}

end_frame :: (renderer: *Renderer) {
    flush(renderer);
    sdl.end_gpu_render_pass(renderer.current_render_pass);
    sdl.submit_gpu_command_buffer(renderer.current_cmd);
    renderer.current_render_pass = null;
    renderer.current_cmd = null;

    time_end_frame();
}

// Begin camera mode - call this before drawing with camera
// begin_camera_mode :: (renderer: *Renderer, camera: *Camera_2D) {
//     flush(renderer); // Flush any pending screen-space draws
//     renderer.camera = camera;
// }

// End camera mode - call this to go back to screen coordinates
// end_camera_mode :: (renderer: *Renderer) {
//     flush(renderer); // Flush any pending camera-space draws
//     renderer.camera = null;
// }

set_camera :: (renderer: *Renderer, camera: *Camera_2D) {
    renderer.camera = camera;
}

get_mvp :: (renderer: *Renderer) -> Matrix4 {
    if renderer.camera != null {
        view := get_view_matrix(renderer.camera);
        return view * renderer.projection;
    }
    return renderer.projection;
}

// Calculate and set renderer viewport for letterbox or pillarbox display
set_viewport :: (renderer: *Renderer, window_width: s32, window_height: s32) {
    target_aspect := cast(float32) renderer.target_width / cast(float32) renderer.target_height;
    window_aspect := cast(float32) window_width / cast(float32) window_height;

    if window_aspect > target_aspect {
        // Pillarbox (clear-color bars on left & right)
        renderer.viewport.h = cast(float32) window_height;
        renderer.viewport.w = renderer.viewport.h * target_aspect;
        renderer.viewport.x = ((cast(float32) window_width) - renderer.viewport.w) * 0.5;
        renderer.viewport.y = 0;
    } else {
        // Letter box (clear-color bars on top & bottom)
        renderer.viewport.w = cast(float32) window_width;
        renderer.viewport.h = renderer.viewport.w / target_aspect;
        renderer.viewport.x = 0;
        renderer.viewport.y = ((cast(float32) window_height) - renderer.viewport.h) * 0.5;
    }

    renderer.viewport.min_depth = 0.0;
    renderer.viewport.max_depth = 1.0;
}

flush_quads :: (renderer: *Renderer) {
    if renderer.frame_quad_vertices.count == 0 return;

    // End current render pass
    sdl.end_gpu_render_pass(renderer.current_render_pass);

    // Upload data via copy pass
    transfer_data := sdl.map_gpu_transfer_buffer(renderer.device, renderer.quad_transfer_buffer, false);
    vertex_size := cast(u32)(size_of(Vertex_Data) * renderer.frame_quad_vertices.count);
    index_size := cast(u32)(size_of(u16) * renderer.frame_quad_indices.count);
    index_ptr := cast(*u8)transfer_data + vertex_size;

    memcpy(transfer_data, renderer.frame_quad_vertices.data, vertex_size);
    memcpy(index_ptr, renderer.frame_quad_indices.data, index_size);
    sdl.unmap_gpu_transfer_buffer(renderer.device, renderer.quad_transfer_buffer);

    copy_pass := sdl.begin_gpu_copy_pass(renderer.current_cmd);

    vertex_location: sdl.GPU_Transfer_Buffer_Location;
    vertex_location.transfer_buffer = renderer.quad_transfer_buffer;
    vertex_region: sdl.GPU_Buffer_Region;
    vertex_region.buffer = renderer.quad_vertex_buffer;
    vertex_region.size = vertex_size;
    sdl.upload_to_gpu_buffer(copy_pass, *vertex_location, *vertex_region, false);

    index_location: sdl.GPU_Transfer_Buffer_Location;
    index_location.transfer_buffer = renderer.quad_transfer_buffer;
    index_location.offset = vertex_size;
    index_region: sdl.GPU_Buffer_Region;
    index_region.buffer = renderer.quad_index_buffer;
    index_region.size = index_size;
    sdl.upload_to_gpu_buffer(copy_pass, *index_location, *index_region, false);

    sdl.end_gpu_copy_pass(copy_pass);

    // Restart render pass with LOAD to preserve previous content
    color_target: sdl.GPU_Color_Target_Info;
    color_target.texture = renderer.swapchain_texture;
    color_target.load_op = .LOAD;
    color_target.store_op = .STORE;
    renderer.current_render_pass = sdl.begin_gpu_render_pass(renderer.current_cmd, *color_target, 1, null);
    if renderer.use_viewport then sdl.set_gpu_viewport(renderer.current_render_pass, *renderer.viewport);

    // Bind and draw
    vertex_binding: sdl.GPU_Buffer_Binding = .{buffer = renderer.quad_vertex_buffer};
    index_binding: sdl.GPU_Buffer_Binding = .{buffer = renderer.quad_index_buffer};

    // Compute MVP - use camera only if use_camera is true
    mvp: Matrix4;
    if renderer.camera {
        view := get_view_matrix(renderer.camera);
        mvp = renderer.projection * view;
    } else {
        mvp = renderer.projection;
    }
    ubo := UBO.{ mvp = mvp };
    sdl.bind_gpu_graphics_pipeline(renderer.current_render_pass, renderer.quad_pipeline);
    sdl.push_gpu_vertex_uniform_data(renderer.current_cmd, 0, *ubo, size_of(UBO));
    sdl.bind_gpu_vertex_buffers(renderer.current_render_pass, 0, *vertex_binding, 1);
    sdl.bind_gpu_index_buffer(renderer.current_render_pass, *index_binding, .SIZE_16BIT);

    for renderer.frame_draws {
        texture_binding: sdl.GPU_Texture_Sampler_Binding = .{texture = it.texture.gpu_texture, sampler = renderer.sampler};
        sdl.bind_gpu_fragment_samplers(renderer.current_render_pass, 0, *texture_binding, 1);
        sdl.draw_gpu_indexed_primitives(renderer.current_render_pass, it.index_count, 1, it.index_offset, cast(s32)it.vertex_offset, 0);
    }

    array_reset(*renderer.frame_quad_vertices);
    array_reset(*renderer.frame_quad_indices);
    array_reset(*renderer.frame_draws);
}

flush_lines :: (renderer: *Renderer) {
    if renderer.frame_line_vertices.count == 0 return;

    sdl.end_gpu_render_pass(renderer.current_render_pass);

    vertex_size := cast(u32)(size_of(Vertex_Data) * renderer.frame_line_vertices.count);
    transfer_data := sdl.map_gpu_transfer_buffer(renderer.device, renderer.line_transfer_buffer, false);
    memcpy(transfer_data, renderer.frame_line_vertices.data, vertex_size);
    sdl.unmap_gpu_transfer_buffer(renderer.device, renderer.line_transfer_buffer);

    copy_pass := sdl.begin_gpu_copy_pass(renderer.current_cmd);

    vertex_location: sdl.GPU_Transfer_Buffer_Location;
    vertex_location.transfer_buffer = renderer.line_transfer_buffer;
    vertex_region: sdl.GPU_Buffer_Region;
    vertex_region.buffer = renderer.line_vertex_buffer;
    vertex_region.size = vertex_size;
    sdl.upload_to_gpu_buffer(copy_pass, *vertex_location, *vertex_region, false);

    sdl.end_gpu_copy_pass(copy_pass);

    color_target: sdl.GPU_Color_Target_Info;
    color_target.texture = renderer.swapchain_texture;
    color_target.load_op = .LOAD;
    color_target.store_op = .STORE;
    renderer.current_render_pass = sdl.begin_gpu_render_pass(renderer.current_cmd, *color_target, 1, null);
    if renderer.use_viewport then sdl.set_gpu_viewport(renderer.current_render_pass, *renderer.viewport);

    vertex_binding: sdl.GPU_Buffer_Binding = .{buffer = renderer.line_vertex_buffer};

    // Compute MVP - use camera only if use_camera is true
    mvp: Matrix4;
    if renderer.camera {
        view := get_view_matrix(renderer.camera);
        mvp = renderer.projection * view;
    } else {
        mvp = renderer.projection;
    }
    ubo := UBO.{ mvp = mvp };
    sdl.bind_gpu_graphics_pipeline(renderer.current_render_pass, renderer.line_pipeline);
    sdl.push_gpu_vertex_uniform_data(renderer.current_cmd, 0, *ubo, size_of(UBO));
    sdl.bind_gpu_vertex_buffers(renderer.current_render_pass, 0, *vertex_binding, 1);

    white_texture_binding: sdl.GPU_Texture_Sampler_Binding = .{texture = renderer.white_texture.gpu_texture, sampler = renderer.sampler};
    sdl.bind_gpu_fragment_samplers(renderer.current_render_pass, 0, *white_texture_binding, 1);

    for renderer.frame_line_draws {
        sdl.draw_gpu_primitives(renderer.current_render_pass, it.vertex_count, 1, it.vertex_offset, 0);
    }

    array_reset(*renderer.frame_line_vertices);
    array_reset(*renderer.frame_line_draws);
}

flush :: (renderer: *Renderer) {
    flush_quads(renderer);
    flush_lines(renderer);
}

/* Textures */

load_texture :: (renderer: *Renderer, path: string) -> *Texture {
    image_data := load_image(path, 4);
    if !image_data {
        log_error("Could not load image: %\n", path);
        return null;
    }
    defer sdl.destroy_surface(image_data);

    texture := New(Texture);
    texture.width = image_data.w;
    texture.height = image_data.h;
    texture.gpu_texture = create_gpu_texture(renderer.device, cast(u32)image_data.w, cast(u32)image_data.h, .R8G8B8A8_UNORM, path);

    // Upload texture data
    texture_transfer_info: sdl.GPU_Transfer_Buffer_Create_Info;
    texture_transfer_info.usage = .UPLOAD;
    texture_transfer_info.size = cast(u32)(image_data.w * image_data.h * 4);
    texture_transfer := sdl.create_gpu_transfer_buffer(renderer.device, *texture_transfer_info);
    defer sdl.release_gpu_transfer_buffer(renderer.device, texture_transfer);

    texture_ptr := cast(*u8)sdl.map_gpu_transfer_buffer(renderer.device, texture_transfer, false);
    memcpy(texture_ptr, image_data.pixels, image_data.w * image_data.h * 4);
    sdl.unmap_gpu_transfer_buffer(renderer.device, texture_transfer);

    cmd := sdl.acquire_gpu_command_buffer(renderer.device);
    copy_pass := sdl.begin_gpu_copy_pass(cmd);

    tex_transfer: sdl.GPU_Texture_Transfer_Info;
    tex_transfer.transfer_buffer = texture_transfer;
    tex_region: sdl.GPU_Texture_Region;
    tex_region.texture = texture.gpu_texture;
    tex_region.w = cast(u32)image_data.w;
    tex_region.h = cast(u32)image_data.h;
    tex_region.d = 1;
    sdl.upload_to_gpu_texture(copy_pass, *tex_transfer, *tex_region, false);

    sdl.end_gpu_copy_pass(copy_pass);
    sdl.submit_gpu_command_buffer(cmd);

    return texture;
}

render_texture :: (renderer: *Renderer, texture: *Texture, src: *sdl.F_Rect, dst: *sdl.F_Rect) {
    render_texture(renderer, texture, src, dst, .{0, 0}, 0.0);
}

render_texture :: (renderer: *Renderer, texture: *Texture, src: *sdl.F_Rect, dst: *sdl.F_Rect, origin: Vector2) {
    render_texture(renderer, texture, src, dst, origin, 0.0);
}

render_texture :: (renderer: *Renderer, texture: *Texture, src: *sdl.F_Rect, dst: *sdl.F_Rect, origin: Vector2 = .{0, 0}, rotation: float = 0) {
    dst_rect: sdl.F_Rect;
    if dst != null {
        dst_rect = dst.*;
    } else {
        if renderer.use_viewport {
            // Fill entire viewport (game coordinates, not window pixels)
            dst_rect = sdl.F_Rect.{0, 0, cast(float)renderer.target_width, cast(float)renderer.target_height};
        } else {
            drawable_width, drawable_height: s32;
            sdl.get_window_size_in_pixels(renderer.window, *drawable_width, *drawable_height);
            dst_rect = sdl.F_Rect.{0, 0, drawable_width.(float), drawable_height.(float)};
        }
    }

    src_rect: sdl.F_Rect;
    if src {
        src_rect = src.*;
    } else {
        src_rect.x = 0;
        src_rect.y = 0;
        src_rect.w = cast(float)texture.width;
        src_rect.h = cast(float)texture.height;
    }

    top_left, top_right, bottom_left, bottom_right: Vector2;

    if rotation == 0.0 {
        x := dst_rect.x - origin.x;
        y := dst_rect.y - origin.y;
        top_left = .{x, y};
        top_right = .{x + dst_rect.w, y};
        bottom_left = .{x, y + dst_rect.h};
        bottom_right = .{x + dst_rect.w, y + dst_rect.h};
    } else {
        // 2D rotation:
        // x' = x*cos(θ) - y*sin(θ)
        // y' = x*sin(θ) + y*cos(θ)

        cos_r := cos(rotation);
        sin_r := sin(rotation);
        x := dst_rect.x;
        y := dst_rect.y;
        dx := -origin.x;
        dy := -origin.y;

        top_left.x = x + dx*cos_r - dy*sin_r;
        top_left.y = y + dx*sin_r + dy*cos_r;

        top_right.x = x + (dx + dst_rect.w)*cos_r - dy*sin_r;
        top_right.y = y + (dx + dst_rect.w)*sin_r + dy*cos_r;

        bottom_left.x = x + dx*cos_r - (dy + dst_rect.h)*sin_r;
        bottom_left.y = y + dx*sin_r + (dy + dst_rect.h)*cos_r;

        bottom_right.x = x + (dx + dst_rect.w)*cos_r - (dy + dst_rect.h)*sin_r;
        bottom_right.y = y + (dx + dst_rect.w)*sin_r + (dy + dst_rect.h)*cos_r;
    }

    u0 := src_rect.x / cast(float)texture.width;
    u1 := (src_rect.x + src_rect.w) / cast(float)texture.width;
    v0 := (src_rect.y + src_rect.h) / cast(float)texture.height; // NOTE(nahua): Texture sampling - v0 and v1 flipped to draw UV upside down since (0, 0) is upper left corner
    v1 := src_rect.y / cast(float)texture.height;                // NOTE(nahua): Texture sampling - v0 and v1 flipped to draw UV upside down since (0, 0) is upper left corner

    vertex_offset := cast(u32)renderer.frame_quad_vertices.count;
    index_offset := cast(u32)renderer.frame_quad_indices.count;

    array_add(*renderer.frame_quad_vertices, .{ position = {top_left.x, top_left.y, 0}, color = {1, 1, 1, 1}, uv = {u0, v1}});
    array_add(*renderer.frame_quad_vertices, .{ position = {bottom_left.x, bottom_left.y, 0}, color = {1, 1, 1, 1}, uv = {u0, v0}});
    array_add(*renderer.frame_quad_vertices, .{ position = {bottom_right.x, bottom_right.y, 0}, color = {1, 1, 1, 1}, uv = {u1, v0}});
    array_add(*renderer.frame_quad_vertices, .{ position = {top_right.x, top_right.y, 0}, color = {1, 1, 1, 1}, uv = {u1, v1}});

    // Use local indices 0-3, vertex_offset will be applied during draw
    array_add(*renderer.frame_quad_indices, 0);
    array_add(*renderer.frame_quad_indices, 1);
    array_add(*renderer.frame_quad_indices, 2);
    array_add(*renderer.frame_quad_indices, 0);
    array_add(*renderer.frame_quad_indices, 2);
    array_add(*renderer.frame_quad_indices, 3);

    draw_call: Draw_Call;
    draw_call.texture = texture;
    draw_call.vertex_offset = vertex_offset;
    draw_call.vertex_count = 4;
    draw_call.index_offset = index_offset;
    draw_call.index_count = 6;
    array_add(*renderer.frame_draws, draw_call);

    // Only flush if necessary
    if renderer.frame_quad_vertices.count >= renderer.max_vertices {
        flush_quads(renderer);
    }
}

/* Shapes */

render_fill_rect :: (renderer: *Renderer, rect: *sdl.F_Rect, color: *sdl.Color) {
    render_fill_rect(renderer, rect, color, .{0, 0}, 0.0);
}

render_fill_rect :: (renderer: *Renderer, rect: *sdl.F_Rect, color: *sdl.Color, origin: Vector2) {
    render_fill_rect(renderer, rect, color, origin, 0.0);
}

render_fill_rect :: (renderer: *Renderer, rect: *sdl.F_Rect, color: *sdl.Color, origin: Vector2 = .{0, 0}, rotation: float = 0) {
    top_left, top_right, bottom_left, bottom_right: Vector2;

    if rotation == 0.0 {
        x := rect.x - origin.x;
        y := rect.y - origin.y;
        top_left = .{x, y};
        top_right = .{x + rect.w, y};
        bottom_left = .{x, y + rect.h};
        bottom_right = .{x + rect.w, y + rect.h};
    } else {
        cos_r := cos(rotation);
        sin_r := sin(rotation);
        x := rect.x;
        y := rect.y;
        dx := -origin.x;
        dy := -origin.y;

        top_left.x = x + dx*cos_r - dy*sin_r;
        top_left.y = y + dx*sin_r + dy*cos_r;

        top_right.x = x + (dx + rect.w)*cos_r - dy*sin_r;
        top_right.y = y + (dx + rect.w)*sin_r + dy*cos_r;

        bottom_left.x = x + dx*cos_r - (dy + rect.h)*sin_r;
        bottom_left.y = y + dx*sin_r + (dy + rect.h)*cos_r;

        bottom_right.x = x + (dx + rect.w)*cos_r - (dy + rect.h)*sin_r;
        bottom_right.y = y + (dx + rect.w)*sin_r + (dy + rect.h)*cos_r;
    }

    vertex_offset := cast(u32)renderer.frame_quad_vertices.count;
    index_offset := cast(u32)renderer.frame_quad_indices.count;

    color_vec4 := Vector4.{
        x = color.r.(float32) / 255.0,
        y = color.g.(float32) / 255.0,
        z = color.b.(float32) / 255.0,
        w = color.a.(float32) / 255.0,
    };

    array_add(*renderer.frame_quad_vertices, .{ position = {top_left.x, top_left.y, 0}, color = color_vec4, uv = {0, 0}});
    array_add(*renderer.frame_quad_vertices, .{ position = {bottom_left.x, bottom_left.y, 0}, color = color_vec4, uv = {0, 0}});
    array_add(*renderer.frame_quad_vertices, .{ position = {bottom_right.x, bottom_right.y, 0}, color = color_vec4, uv = {0, 0}});
    array_add(*renderer.frame_quad_vertices, .{ position = {top_right.x, top_right.y, 0}, color = color_vec4, uv = {0, 0}});

    // Use local indices 0-3, vertex_offset will be applied during draw
    array_add(*renderer.frame_quad_indices, 0);
    array_add(*renderer.frame_quad_indices, 1);
    array_add(*renderer.frame_quad_indices, 2);
    array_add(*renderer.frame_quad_indices, 0);
    array_add(*renderer.frame_quad_indices, 2);
    array_add(*renderer.frame_quad_indices, 3);

    draw_call: Draw_Call;
    draw_call.texture = renderer.white_texture;
    draw_call.vertex_offset = vertex_offset;
    draw_call.vertex_count = 4;
    draw_call.index_offset = index_offset;
    draw_call.index_count = 6;
    array_add(*renderer.frame_draws, draw_call);

    // Only flush if necessary
    if renderer.frame_quad_vertices.count >= renderer.max_vertices {
        flush_quads(renderer);
    }
}

render_rect :: (renderer: *Renderer, rect: *sdl.F_Rect, color: *sdl.Color) {
    render_rect(renderer, rect, color, .{0, 0}, 0.0);
}

render_rect :: (renderer: *Renderer, rect: *sdl.F_Rect, color: *sdl.Color, origin: Vector2) {
    render_rect(renderer, rect, color, origin, 0.0);
}

render_rect :: (renderer: *Renderer, rect: *sdl.F_Rect, color: *sdl.Color, origin: Vector2 = .{0, 0}, rotation: float = 0) {
    x_offset : float32 : 0.5;
    y_offset : float32 : 0.5;

    top_left, top_right, bottom_left, bottom_right: Vector2;

    if rotation == 0.0 {
        x := rect.x - origin.x + x_offset;
        y := rect.y - origin.y + y_offset;
        top_left = .{x, y};
        top_right = .{x + rect.w - x_offset*2, y};
        bottom_left = .{x, y + rect.h - y_offset*2};
        bottom_right = .{x + rect.w - x_offset*2, y + rect.h - y_offset*2};
    } else {
        cos_r := cos(rotation);
        sin_r := sin(rotation);
        x := rect.x;
        y := rect.y;
        dx := -origin.x + x_offset;
        dy := -origin.y + y_offset;
        w := rect.w - x_offset*2;
        h := rect.h - y_offset*2;

        top_left.x = x + dx*cos_r - dy*sin_r;
        top_left.y = y + dx*sin_r + dy*cos_r;

        top_right.x = x + (dx + w)*cos_r - dy*sin_r;
        top_right.y = y + (dx + w)*sin_r + dy*cos_r;

        bottom_left.x = x + dx*cos_r - (dy + h)*sin_r;
        bottom_left.y = y + dx*sin_r + (dy + h)*cos_r;

        bottom_right.x = x + (dx + w)*cos_r - (dy + h)*sin_r;
        bottom_right.y = y + (dx + w)*sin_r + (dy + h)*cos_r;
    }

    color_vec4 := Vector4.{
        x = color.r.(float32) / 255.0,
        y = color.g.(float32) / 255.0,
        z = color.b.(float32) / 255.0,
        w = color.a.(float32) / 255.0,
    };

    vertex_offset := cast(u32)renderer.frame_line_vertices.count;

    array_add(*renderer.frame_line_vertices, .{ position = {top_left.x, top_left.y, 0}, color = color_vec4, uv = {0, 0}});
    array_add(*renderer.frame_line_vertices, .{ position = {top_right.x, top_right.y, 0}, color = color_vec4, uv = {0, 0}});

    array_add(*renderer.frame_line_vertices, .{ position = {top_right.x, top_right.y, 0}, color = color_vec4, uv = {0, 0}});
    array_add(*renderer.frame_line_vertices, .{ position = {bottom_right.x, bottom_right.y, 0}, color = color_vec4, uv = {0, 0}});

    array_add(*renderer.frame_line_vertices, .{ position = {bottom_right.x, bottom_right.y, 0}, color = color_vec4, uv = {0, 0}});
    array_add(*renderer.frame_line_vertices, .{ position = {bottom_left.x, bottom_left.y, 0}, color = color_vec4, uv = {0, 0}});

    array_add(*renderer.frame_line_vertices, .{ position = {bottom_left.x, bottom_left.y, 0}, color = color_vec4, uv = {0, 0}});
    array_add(*renderer.frame_line_vertices, .{ position = {top_left.x, top_left.y, 0}, color = color_vec4, uv = {0, 0}});

    line_draw: Line_Draw_Call;
    line_draw.vertex_offset = vertex_offset;
    line_draw.vertex_count = 8;
    array_add(*renderer.frame_line_draws, line_draw);

    // Only flush if necessary
    if renderer.frame_line_vertices.count >= renderer.max_line_vertices {
        flush_lines(renderer);
    }
}
