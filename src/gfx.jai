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
    index_start: u32;
    index_count: u32;
}

Renderer :: struct {
    device: *sdl.GPU_Device;
    window: *sdl.Window;

    current_render_pass: *sdl.GPU_Render_Pass;
    current_cmd: *sdl.GPU_Command_Buffer;
    swapchain_texture: *sdl.GPU_Texture;

    quad_pipeline: *sdl.GPU_Graphics_Pipeline;
    line_pipeline: *sdl.GPU_Graphics_Pipeline;
    sampler: *sdl.GPU_Sampler;

    quad_vertex_buffer: *sdl.GPU_Buffer;
    quad_index_buffer: *sdl.GPU_Buffer;
    quad_transfer_buffer: *sdl.GPU_Transfer_Buffer;

    line_vertex_buffer: *sdl.GPU_Buffer;
    line_transfer_buffer: *sdl.GPU_Transfer_Buffer;

    /* Triangle batch data */
    batch_vertices: [..]Vertex_Data;
    batch_indices: [..]u16;
    batch_draws: [..]Draw_Call;

    /* Line batch data */
    line_vertices: [..]Vertex_Data;

    max_sprites_per_batch: int;
    max_lines_per_batch: int;

    projection: Matrix4;

    white_texture: *Texture;
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

begin_frame :: (renderer: *Renderer) -> bool {
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

    return true;
}

flush_triangles :: (renderer: *Renderer) {
    if renderer.batch_vertices.count == 0 return;

    // End current render pass
    sdl.end_gpu_render_pass(renderer.current_render_pass);

    // Upload data via copy pass
    transfer_data := sdl.map_gpu_transfer_buffer(renderer.device, renderer.quad_transfer_buffer, false);
    vertex_size := cast(u32)(size_of(Vertex_Data) * renderer.batch_vertices.count);
    index_size := cast(u32)(size_of(u16) * renderer.batch_indices.count);
    index_ptr := cast(*u8)transfer_data + vertex_size;

    memcpy(transfer_data, renderer.batch_vertices.data, vertex_size);
    memcpy(index_ptr, renderer.batch_indices.data, index_size);
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

    // Bind and draw
    vertex_binding: sdl.GPU_Buffer_Binding = .{buffer = renderer.quad_vertex_buffer};
    index_binding: sdl.GPU_Buffer_Binding = .{buffer = renderer.quad_index_buffer};

    ubo := UBO.{ mvp = renderer.projection };
    sdl.bind_gpu_graphics_pipeline(renderer.current_render_pass, renderer.quad_pipeline);
    sdl.push_gpu_vertex_uniform_data(renderer.current_cmd, 0, *ubo, size_of(UBO));
    sdl.bind_gpu_vertex_buffers(renderer.current_render_pass, 0, *vertex_binding, 1);
    sdl.bind_gpu_index_buffer(renderer.current_render_pass, *index_binding, .SIZE_16BIT);

    for renderer.batch_draws {
        texture_binding: sdl.GPU_Texture_Sampler_Binding = .{texture = it.texture.gpu_texture, sampler = renderer.sampler};
        sdl.bind_gpu_fragment_samplers(renderer.current_render_pass, 0, *texture_binding, 1);
        sdl.draw_gpu_indexed_primitives(renderer.current_render_pass, it.index_count, 1, it.index_start, 0, 0);
    }

    array_reset(*renderer.batch_vertices);
    array_reset(*renderer.batch_indices);
    array_reset(*renderer.batch_draws);
}

flush_lines :: (renderer: *Renderer) {
    if renderer.line_vertices.count == 0 return;

    sdl.end_gpu_render_pass(renderer.current_render_pass);

    vertex_size := cast(u32)(size_of(Vertex_Data) * renderer.line_vertices.count);
    transfer_data := sdl.map_gpu_transfer_buffer(renderer.device, renderer.line_transfer_buffer, false);  // Changed
    memcpy(transfer_data, renderer.line_vertices.data, vertex_size);
    sdl.unmap_gpu_transfer_buffer(renderer.device, renderer.line_transfer_buffer);  // Changed

    copy_pass := sdl.begin_gpu_copy_pass(renderer.current_cmd);

    vertex_location: sdl.GPU_Transfer_Buffer_Location;
    vertex_location.transfer_buffer = renderer.line_transfer_buffer;  // Changed
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

    vertex_binding: sdl.GPU_Buffer_Binding = .{buffer = renderer.line_vertex_buffer};

    ubo := UBO.{ mvp = renderer.projection };
    sdl.bind_gpu_graphics_pipeline(renderer.current_render_pass, renderer.line_pipeline);
    sdl.push_gpu_vertex_uniform_data(renderer.current_cmd, 0, *ubo, size_of(UBO));
    sdl.bind_gpu_vertex_buffers(renderer.current_render_pass, 0, *vertex_binding, 1);

    white_texture_binding: sdl.GPU_Texture_Sampler_Binding = .{texture = renderer.white_texture.gpu_texture, sampler = renderer.sampler};
    sdl.bind_gpu_fragment_samplers(renderer.current_render_pass, 0, *white_texture_binding, 1);
    sdl.draw_gpu_primitives(renderer.current_render_pass, cast(u32)renderer.line_vertices.count, 1, 0, 0);

    array_reset(*renderer.line_vertices);
}

flush :: (renderer: *Renderer) {
    flush_triangles(renderer);
    flush_lines(renderer);
}

end_frame :: (renderer: *Renderer) {
    flush(renderer);
    sdl.end_gpu_render_pass(renderer.current_render_pass);
    sdl.submit_gpu_command_buffer(renderer.current_cmd);
    renderer.current_render_pass = null;
    renderer.current_cmd = null;
}

render_texture :: (renderer: *Renderer, texture: *Texture, src: *sdl.F_Rect, dst: *sdl.F_Rect) {
    dst_rect: sdl.F_Rect;
    if dst != null {
        dst_rect = dst.*;
    } else {
        drawable_width, drawable_height: s32;
        sdl.get_window_size_in_pixels(renderer.window, *drawable_width, *drawable_height);
        dst_rect = sdl.F_Rect.{0, 0, drawable_width.(float), drawable_height.(float)};
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

    x0 := dst_rect.x;
    y0 := dst_rect.y;
    x1 := dst_rect.x + dst_rect.w;
    y1 := dst_rect.y + dst_rect.h;

    u0 := src_rect.x / cast(float)texture.width;
    u1 := (src_rect.x + src_rect.w) / cast(float)texture.width;
    v0 := (src_rect.y + src_rect.h) / cast(float)texture.height; // NOTE(nahua): Texture sampling - v0 and v1 flipped to draw UV upside down since (0, 0) is upper left corner
    v1 := src_rect.y / cast(float)texture.height;                // NOTE(nahua): Texture sampling - v0 and v1 flipped to draw UV upside down since (0, 0) is upper left corner

    base_vertex := cast(u16)renderer.batch_vertices.count;

    array_add(*renderer.batch_vertices, .{ position = {x0, y1, 0}, color = {1, 1, 1, 1}, uv = {u0, v0}});
    array_add(*renderer.batch_vertices, .{ position = {x1, y1, 0}, color = {1, 1, 1, 1}, uv = {u1, v0}});
    array_add(*renderer.batch_vertices, .{ position = {x1, y0, 0}, color = {1, 1, 1, 1}, uv = {u1, v1}});
    array_add(*renderer.batch_vertices, .{ position = {x0, y0, 0}, color = {1, 1, 1, 1}, uv = {u0, v1}});

    index_start := cast(u32)renderer.batch_indices.count;
    array_add(*renderer.batch_indices, base_vertex + 0);
    array_add(*renderer.batch_indices, base_vertex + 1);
    array_add(*renderer.batch_indices, base_vertex + 2);
    array_add(*renderer.batch_indices, base_vertex + 0);
    array_add(*renderer.batch_indices, base_vertex + 2);
    array_add(*renderer.batch_indices, base_vertex + 3);

    draw_call: Draw_Call;
    draw_call.texture = texture;
    draw_call.index_start = index_start;
    draw_call.index_count = 6;
    array_add(*renderer.batch_draws, draw_call);

    if renderer.batch_vertices.count >= renderer.max_sprites_per_batch * 4 {
        flush_triangles(renderer);
    }
}

render_fill_rect :: (renderer: *Renderer, rect: *sdl.F_Rect, color: *sdl.Color) {
    x0 := rect.x;
    y0 := rect.y;
    x1 := rect.x + rect.w;
    y1 := rect.y + rect.h;

    base_vertex := cast(u16)renderer.batch_vertices.count;

    color_vec4 := Vector4.{
        x = color.r.(float32) / 255.0,
        y = color.g.(float32) / 255.0,
        z = color.b.(float32) / 255.0,
        w = color.a.(float32) / 255.0,
    };

    array_add(*renderer.batch_vertices, .{ position = {x0, y1, 0}, color = color_vec4, uv = {0, 0}});
    array_add(*renderer.batch_vertices, .{ position = {x1, y1, 0}, color = color_vec4, uv = {0, 0}});
    array_add(*renderer.batch_vertices, .{ position = {x1, y0, 0}, color = color_vec4, uv = {0, 0}});
    array_add(*renderer.batch_vertices, .{ position = {x0, y0, 0}, color = color_vec4, uv = {0, 0}});

    index_start := cast(u32)renderer.batch_indices.count;
    array_add(*renderer.batch_indices, base_vertex + 0);
    array_add(*renderer.batch_indices, base_vertex + 1);
    array_add(*renderer.batch_indices, base_vertex + 2);
    array_add(*renderer.batch_indices, base_vertex + 0);
    array_add(*renderer.batch_indices, base_vertex + 2);
    array_add(*renderer.batch_indices, base_vertex + 3);

    draw_call: Draw_Call;
    draw_call.texture = renderer.white_texture;
    draw_call.index_start = index_start;
    draw_call.index_count = 6;
    array_add(*renderer.batch_draws, draw_call);

    if renderer.batch_vertices.count >= renderer.max_sprites_per_batch * 4 {
        flush_triangles(renderer);
    }
}

render_rect :: (renderer: *Renderer, rect: *sdl.F_Rect, color: *sdl.Color) {
    x0 := rect.x;
    y0 := rect.y;
    x1 := rect.x + rect.w;
    y1 := rect.y + rect.h;

    color_vec4 := Vector4.{
        x = color.r.(float32) / 255.0,
        y = color.g.(float32) / 255.0,
        z = color.b.(float32) / 255.0,
        w = color.a.(float32) / 255.0,
    };

    // Top edge
    array_add(*renderer.line_vertices, .{ position = {x0, y0, 0}, color = color_vec4, uv = {0, 0}});
    array_add(*renderer.line_vertices, .{ position = {x1, y0, 0}, color = color_vec4, uv = {0, 0}});

    // Right edge
    array_add(*renderer.line_vertices, .{ position = {x1, y0, 0}, color = color_vec4, uv = {0, 0}});
    array_add(*renderer.line_vertices, .{ position = {x1, y1, 0}, color = color_vec4, uv = {0, 0}});

    // Bottom edge
    array_add(*renderer.line_vertices, .{ position = {x1, y1, 0}, color = color_vec4, uv = {0, 0}});
    array_add(*renderer.line_vertices, .{ position = {x0, y1, 0}, color = color_vec4, uv = {0, 0}});

    // Left edge (now closes the loop properly)
    array_add(*renderer.line_vertices, .{ position = {x0, y1, 0}, color = color_vec4, uv = {0, 0}});
    array_add(*renderer.line_vertices, .{ position = {x0, y0, 0}, color = color_vec4, uv = {0, 0}});

    if renderer.line_vertices.count >= renderer.max_lines_per_batch * 2 {
        flush_lines(renderer);
    }
}
