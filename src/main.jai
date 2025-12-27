#import "Basic";
#import "File";
#import "Math";
#import "String";
#import "Windows";
sdl :: #import "SDL3";
img :: #import "SDL3/image";

#load "asset.jai";
#load "image.jai";
#load "shader.jai";

DEBUG         :: 1;
WINDOW_WIDTH  :: 800;
WINDOW_HEIGHT :: 600;

base_path: string;
device:    *sdl.GPU_Device;
window:    *sdl.Window;

PositionTextureVertex :: struct {
    x, y, z: float;
    u, v:    float;
}

create_pipeline :: (
    vertex_shader:       *sdl.GPU_Shader,
    fragment_shader:     *sdl.GPU_Shader,
    vertex_input_state:  sdl.GPU_Vertex_Input_State,
    primitive_type:      sdl.GPU_Primitive_Type = sdl.GPU_Primitive_Type.TRIANGLELIST
) -> *sdl.GPU_Graphics_Pipeline {
    swapchain_format: sdl.GPU_Texture_Format            = sdl.get_gpu_swapchain_texture_format(device, window);
    color_target:     sdl.GPU_Color_Target_Description;
    color_target.format                                 = swapchain_format;

    pipeline_info: sdl.GPU_Graphics_Pipeline_Create_Info;
    pipeline_info.vertex_shader                         = vertex_shader;
    pipeline_info.fragment_shader                       = fragment_shader;
    pipeline_info.vertex_input_state                    = vertex_input_state;
    pipeline_info.primitive_type                        = primitive_type;
    pipeline_info.target_info.num_color_targets         = 1;                  // TODO(nahua): We assume 1 color target for now
    pipeline_info.target_info.color_target_descriptions = *color_target;

    return sdl.create_gpu_graphics_pipeline(device, *pipeline_info);
}

create_sampler :: (
    min_filter:     sdl.GPU_Filter               = .NEAREST,
    mag_filter:     sdl.GPU_Filter               = .NEAREST,
    mipmap_mode:    sdl.GPU_Sampler_Mipmap_Mode  = .NEAREST,
    address_mode_u: sdl.GPU_Sampler_Address_Mode = .CLAMP_TO_EDGE,
    address_mode_v: sdl.GPU_Sampler_Address_Mode = .CLAMP_TO_EDGE,
    address_mode_w: sdl.GPU_Sampler_Address_Mode = .CLAMP_TO_EDGE
) -> *sdl.GPU_Sampler {
    info: sdl.GPU_Sampler_Create_Info;
    info.min_filter     = min_filter;
    info.mag_filter     = mag_filter;
    info.mipmap_mode    = mipmap_mode;
    info.address_mode_u = address_mode_u;
    info.address_mode_v = address_mode_v;
    info.address_mode_w = address_mode_w;

    return sdl.create_gpu_sampler(device, *info);
}

create_gpu_buffer :: (usage: sdl.GPU_Buffer_Usage_Flags, size: u32, name: string = "") -> *sdl.GPU_Buffer {
    info: sdl.GPU_Buffer_Create_Info;
    info.usage              = usage;
    info.size               = size;
    buffer: *sdl.GPU_Buffer = sdl.create_gpu_buffer(device, *info);

    if name && buffer sdl.set_gpu_buffer_name(device, buffer, name.data);

    return buffer;
}

create_gpu_texture :: (w: u32, h: u32, format: sdl.GPU_Texture_Format, name: string = "") -> *sdl.GPU_Texture {
    info: sdl.GPU_Texture_Create_Info;
    info.type                 = .TYPE_2D;
    info.format               = format;
    info.width                = w;
    info.height               = h;
    info.layer_count_or_depth = 1;
    info.num_levels           = 1;
    info.usage                = .SAMPLER;
    texture: *sdl.GPU_Texture = sdl.create_gpu_texture(device, *info);

    if name && texture sdl.set_gpu_texture_name(device, texture, name.data);

    return texture;
}

upload_buffers_and_texture :: (
    vertex_buffer: *sdl.GPU_Buffer,
    index_buffer:  *sdl.GPU_Buffer,
    texture:       *sdl.GPU_Texture,
    vertices:      []PositionTextureVertex,
    indices:       []u16,
    image_data:    *sdl.Surface
) {
    total_size := cast(u32)(size_of(PositionTextureVertex) * vertices.count + size_of(u16) * indices.count);

    buffer_transfer_info: sdl.GPU_Transfer_Buffer_Create_Info;
    buffer_transfer_info.usage                = .UPLOAD;
    buffer_transfer_info.size                 = total_size;
    buffer_transfer: *sdl.GPU_Transfer_Buffer = sdl.create_gpu_transfer_buffer(device, *buffer_transfer_info);
    defer sdl.release_gpu_transfer_buffer(device, buffer_transfer);

    transfer_data := sdl.map_gpu_transfer_buffer(device, buffer_transfer, false);
    index_ptr     := cast(*u8)transfer_data + size_of(PositionTextureVertex) * vertices.count;
    memcpy(transfer_data, vertices.data, size_of(PositionTextureVertex) * vertices.count);
    memcpy(index_ptr, indices.data, size_of(u16) * indices.count);
    sdl.unmap_gpu_transfer_buffer(device, buffer_transfer);

    texture_transfer_info: sdl.GPU_Transfer_Buffer_Create_Info;
    texture_transfer_info.usage = .UPLOAD;
    texture_transfer_info.size = cast(u32)(image_data.w * image_data.h * 4);
    texture_transfer := sdl.create_gpu_transfer_buffer(device, *texture_transfer_info);
    defer sdl.release_gpu_transfer_buffer(device, texture_transfer);

    texture_ptr := cast(*u8)sdl.map_gpu_transfer_buffer(device, texture_transfer, false);
    memcpy(texture_ptr, image_data.pixels, image_data.w * image_data.h * 4);
    sdl.unmap_gpu_transfer_buffer(device, texture_transfer);

    cmd := sdl.acquire_gpu_command_buffer(device);
    copy_pass := sdl.begin_gpu_copy_pass(cmd);

    vertex_location: sdl.GPU_Transfer_Buffer_Location;
    vertex_location.transfer_buffer = buffer_transfer;
    vertex_region: sdl.GPU_Buffer_Region;
    vertex_region.buffer = vertex_buffer;
    vertex_region.size = cast(u32)(size_of(PositionTextureVertex) * vertices.count);
    sdl.upload_to_gpu_buffer(copy_pass, *vertex_location, *vertex_region, false);

    index_location: sdl.GPU_Transfer_Buffer_Location;
    index_location.transfer_buffer = buffer_transfer;
    index_location.offset = cast(u32)(size_of(PositionTextureVertex) * vertices.count);
    index_region: sdl.GPU_Buffer_Region;
    index_region.buffer = index_buffer;
    index_region.size = cast(u32)(size_of(u16) * indices.count);
    sdl.upload_to_gpu_buffer(copy_pass, *index_location, *index_region, false);

    tex_transfer: sdl.GPU_Texture_Transfer_Info;
    tex_transfer.transfer_buffer = texture_transfer;
    tex_region: sdl.GPU_Texture_Region;
    tex_region.texture = texture;
    tex_region.w = cast(u32)image_data.w;
    tex_region.h = cast(u32)image_data.h;
    tex_region.d = 1;
    sdl.upload_to_gpu_texture(copy_pass, *tex_transfer, *tex_region, false);

    sdl.end_gpu_copy_pass(copy_pass);
    sdl.submit_gpu_command_buffer(cmd);
}

main :: () {
    if !sdl.init(sdl.Init_Flags.VIDEO) {
        log_error("Could not initialize SDL: %\n", to_string(sdl.get_error()));
        return;
    }

    device = sdl.create_gpu_device(
        sdl.GPU_Shader_Format.SPIRV | sdl.GPU_Shader_Format.DXIL | sdl.GPU_Shader_Format.MSL,
        true, null
    );
    if !device {
        log_error("SDL_CreateDevice failed: %\n", to_string(sdl.get_error()));
        return;
    }

    window = sdl.create_window("SDL3 GPU in Jai", WINDOW_WIDTH, WINDOW_HEIGHT, sdl.Window_Flags.RESIZABLE);
    if !window {
        log_error("Could not create window: %\n", to_string(sdl.get_error()));
        return;
    }

    if !sdl.claim_window_for_gpu_device(device, window) {
        log_error("SDL_ClaimWindowForGPUDevice failed: %\n", to_string(sdl.get_error()));
        return;
    }

    initialize_asset_loader();

    vertex_shader := load_shader(device, "assets/shaders/TexturedQuad.vert", 0, 0, 0, 0);
    if !vertex_shader {
        log_error("Failed to create vertex shader\n");
        return;
    }

    fragment_shader := load_shader(device, "assets/shaders/TexturedQuad.frag", 1, 0, 0, 0);
    if !fragment_shader {
        log_error("Failed to create fragment shader\n");
        return;
    }

    image_data := load_image_bmp("assets/images/lettuce.bmp", 4);
    if !image_data {
        log_error("Could not load image data\n");
        return;
    }
    defer sdl.destroy_surface(image_data);

    vertex_buffer_desc: sdl.GPU_Vertex_Buffer_Description;
    vertex_buffer_desc.pitch = size_of(PositionTextureVertex);
    vertex_buffer_desc.input_rate = .VERTEX;

    vertex_attributes: [2]sdl.GPU_Vertex_Attribute = .[
        {location = 0, buffer_slot = 0, format = .FLOAT3, offset = 0},
        {location = 1, buffer_slot = 0, format = .FLOAT2, offset = size_of(float) * 3}
    ];

    vertex_input_state: sdl.GPU_Vertex_Input_State;
    vertex_input_state.num_vertex_buffers = 1;
    vertex_input_state.vertex_buffer_descriptions = *vertex_buffer_desc;
    vertex_input_state.num_vertex_attributes = 2;
    vertex_input_state.vertex_attributes = vertex_attributes.data;

    pipeline := create_pipeline(vertex_shader, fragment_shader, vertex_input_state);
    if !pipeline {
        log_error("Failed to create pipeline\n");
        return;
    }
    defer sdl.release_gpu_graphics_pipeline(device, pipeline);

    sdl.release_gpu_shader(device, vertex_shader);
    sdl.release_gpu_shader(device, fragment_shader);

    sampler       := create_sampler();
    vertex_buffer := create_gpu_buffer(.VERTEX, size_of(PositionTextureVertex) * 4, "Lettuce Vertex Buffer");
    index_buffer  := create_gpu_buffer(.INDEX, size_of(u16) * 6);
    texture       := create_gpu_texture(cast(u32)image_data.w, cast(u32)image_data.h, .R8G8B8A8_UNORM, "Lettuce Texture");

    vertices: [4]PositionTextureVertex = .[
        .{-1,  1, 0, 0, 0},
        .{ 1,  1, 0, 1, 0},
        .{ 1, -1, 0, 1, 1},
        .{-1, -1, 0, 0, 1}
    ];
    indices: [6]u16 = .[0, 1, 2, 0, 2, 3];

    upload_buffers_and_texture(vertex_buffer, index_buffer, texture, vertices, indices, image_data);

    exit := false;
    while !exit {
        event: sdl.Event;
        while sdl.poll_event(*event) {
            if event.type == {
                case .QUIT; exit = true;
                case .KEY_UP; if event.key.key == .ESCAPE exit = true;
            }
        }

        cmd := sdl.acquire_gpu_command_buffer(device);
        if !cmd {
            log_error("SDL_AcquireGPUCommandBuffer failed: %\n", to_string(sdl.get_error()));
            return;
        }

        swapchain_texture: *sdl.GPU_Texture;
        acquired := sdl.wait_and_acquire_gpu_swapchain_texture(cmd, window, *swapchain_texture, null, null);
        assert(acquired);

        if swapchain_texture {
            color_target: sdl.GPU_Color_Target_Info;
            color_target.texture     = swapchain_texture;
            color_target.clear_color = .{0.3, 0.6, 0.5, 1.0};
            color_target.load_op     = .CLEAR;
            color_target.store_op    = .STORE;

            render_pass := sdl.begin_gpu_render_pass(cmd, *color_target, 1, null);

            vertex_binding: sdl.GPU_Buffer_Binding           = .{buffer = vertex_buffer};
            index_binding: sdl.GPU_Buffer_Binding            = .{buffer = index_buffer};
            texture_binding: sdl.GPU_Texture_Sampler_Binding = .{texture = texture, sampler = sampler};

            sdl.bind_gpu_graphics_pipeline(render_pass, pipeline);
            sdl.bind_gpu_vertex_buffers(render_pass, 0, *vertex_binding, 1);
            sdl.bind_gpu_index_buffer(render_pass, *index_binding, .SIZE_16BIT);
            sdl.bind_gpu_fragment_samplers(render_pass, 0, *texture_binding, 1);
            sdl.draw_gpu_indexed_primitives(render_pass, 6, 1, 0, 0, 0);

            sdl.end_gpu_render_pass(render_pass);
        }

        sdl.submit_gpu_command_buffer(cmd);
    }

    sdl.destroy_window(window);
    sdl.quit();
}
