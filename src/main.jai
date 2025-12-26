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
renderer:  *sdl.Renderer;
window:    *sdl.Window;
hwnd:      *void;

PositionTextureVertex :: struct {
    x, y, z: float;
    u, v:    float;
}

main :: () {
    if !sdl.init(sdl.Init_Flags.VIDEO) {
        log_error("Could not initialize SDL: %\n", to_string(sdl.get_error()));
        return;
    }

    device = sdl.create_gpu_device(
        sdl.GPU_Shader_Format.SPIRV | sdl.GPU_Shader_Format.DXIL | sdl.GPU_Shader_Format.MSL,
        true,
        null,
    );
    if device == null {
        log_error("SDL_CreateDevice failed: %\n", to_string(sdl.get_error()));
        return;
    }

    window = sdl.create_window(
        "SDL3 GPU in Jai",
        WINDOW_WIDTH, WINDOW_HEIGHT,
        sdl.Window_Flags.RESIZABLE,
    );
    if window == null {
        log_error("Could not create window: %\n", to_string(sdl.get_error()));
        sdl.quit();
        return;
    }

    if !sdl.claim_window_for_gpu_device(device, window) {
        log_error("SDL_ClaimWindowForGPUDevice failed: %\n", to_string(sdl.get_error()));
        return;
    }

    initialize_asset_loader();

    /*
       TEXTURED QUAD
    */
    textured_quad_vertex_shader_path := "assets/shaders/TexturedQuad.vert";
    textured_quad_vertex_shader := load_shader(device, textured_quad_vertex_shader_path, 0, 0, 0, 0);
    if textured_quad_vertex_shader == null {
        log_error("Failed to create vertex shader\n");
        return;
    }
    print("Vertex shader loaded: %\n", textured_quad_vertex_shader);

    textured_quad_fragment_shader_path := "assets/shaders/TexturedQuad.frag";
    textured_quad_fragment_shader := load_shader(device, textured_quad_fragment_shader_path, 1, 0, 0, 0);
    if textured_quad_fragment_shader == null {
        log_error("Failed to create fragment shader\n");
        return;
    }
    print("Fragment shader loaded: %\n", textured_quad_fragment_shader);

    textured_quad_image_path := "assets/images/lettuce.bmp";
    textured_quad_image_data := load_image_bmp(textured_quad_image_path, 4);
    if textured_quad_image_data == null {
        log_error("Could not load image data: %\n", textured_quad_image_path);
        return;
    }
    print("Texture loaded: %\n", textured_quad_image_data);

    textured_quad_color_target_descriptions: sdl.GPU_Color_Target_Description;
    textured_quad_color_target_descriptions.format = sdl.get_gpu_swapchain_texture_format(device, window);

    textured_quad_gpu_vertex_buffer_description: sdl.GPU_Vertex_Buffer_Description;
    textured_quad_gpu_vertex_buffer_description.slot               = 0;
    textured_quad_gpu_vertex_buffer_description.input_rate         = sdl.GPU_Vertex_Input_Rate.VERTEX;
    textured_quad_gpu_vertex_buffer_description.instance_step_rate = 0;
    textured_quad_gpu_vertex_buffer_description.pitch              = size_of(PositionTextureVertex);

    textured_quad_gpu_vertex_attributes: [2]sdl.GPU_Vertex_Attribute = .[
        {
            location    = 0,
            buffer_slot = 0,
            format      = sdl.GPU_Vertex_Element_Format.FLOAT3,
            offset      = 0,
        },
        {
            location    = 1,
            buffer_slot = 0,
            format      = sdl.GPU_Vertex_Element_Format.FLOAT2,
            offset      = size_of(float) * 3,
        }
    ];

    textured_quad_vertex_input_state: sdl.GPU_Vertex_Input_State;
    textured_quad_vertex_input_state.num_vertex_buffers         = 1;
    textured_quad_vertex_input_state.num_vertex_attributes      = 2;
    textured_quad_vertex_input_state.vertex_attributes          = textured_quad_gpu_vertex_attributes.data;
    textured_quad_vertex_input_state.vertex_buffer_descriptions = *textured_quad_gpu_vertex_buffer_description;

    textured_quad_pipeline_create_info: sdl.GPU_Graphics_Pipeline_Create_Info;
    textured_quad_pipeline_create_info.vertex_shader              = textured_quad_vertex_shader;
    textured_quad_pipeline_create_info.fragment_shader            = textured_quad_fragment_shader;
    textured_quad_pipeline_create_info.vertex_input_state         = textured_quad_vertex_input_state;
    textured_quad_pipeline_create_info.primitive_type             = sdl.GPU_Primitive_Type.TRIANGLELIST;
    textured_quad_pipeline_create_info.target_info                = sdl.GPU_Graphics_Pipeline_Target_Info.{
        num_color_targets         = 1,
        color_target_descriptions = *textured_quad_color_target_descriptions,
    };

    textured_quad_pipeline: *sdl.GPU_Graphics_Pipeline;
    textured_quad_pipeline = sdl.create_gpu_graphics_pipeline(device, *textured_quad_pipeline_create_info);
    if textured_quad_pipeline == null {
        log_error("Failed to create fill pipeline\n");
        return;
    }
    sdl.release_gpu_shader(device, textured_quad_vertex_shader);
    sdl.release_gpu_shader(device, textured_quad_fragment_shader);

    textured_quad_sampler_info: sdl.GPU_Sampler_Create_Info;
    textured_quad_sampler_info.min_filter     = sdl.GPU_Filter.NEAREST;
    textured_quad_sampler_info.mag_filter     = sdl.GPU_Filter.NEAREST;
    textured_quad_sampler_info.mipmap_mode    = sdl.GPU_Sampler_Mipmap_Mode.NEAREST;
    textured_quad_sampler_info.address_mode_u = sdl.GPU_Sampler_Address_Mode.CLAMP_TO_EDGE;
    textured_quad_sampler_info.address_mode_v = sdl.GPU_Sampler_Address_Mode.CLAMP_TO_EDGE;
    textured_quad_sampler_info.address_mode_w = sdl.GPU_Sampler_Address_Mode.CLAMP_TO_EDGE;
    textured_quad_sampler: *sdl.GPU_Sampler = sdl.create_gpu_sampler(device, *textured_quad_sampler_info);

    // Textured Quad Vertex Buffer
    textured_quad_vertex_buffer_info: sdl.GPU_Buffer_Create_Info;
    textured_quad_vertex_buffer_info.usage = sdl.GPU_Buffer_Usage_Flags.VERTEX;
    textured_quad_vertex_buffer_info.size  = size_of(PositionTextureVertex) * 4;
    textured_quad_vertex_buffer := sdl.create_gpu_buffer(device, *textured_quad_vertex_buffer_info);
    sdl.set_gpu_buffer_name(device, textured_quad_vertex_buffer, "Lettuce Vertex Buffer");
    // Textured Quad Index Buffer
    textured_quad_index_buffer_info: sdl.GPU_Buffer_Create_Info;
    textured_quad_index_buffer_info.usage = sdl.GPU_Buffer_Usage_Flags.INDEX;
    textured_quad_index_buffer_info.size  = size_of(u16) * 6;
    textured_quad_index_buffer := sdl.create_gpu_buffer(device, *textured_quad_index_buffer_info);
    // Textured Quad Texture
    textured_quad_texture_info: sdl.GPU_Texture_Create_Info;
    textured_quad_texture_info.type                 = sdl.GPU_Texture_Type.TYPE_2D;
    textured_quad_texture_info.format               = sdl.GPU_Texture_Format.R8G8B8A8_UNORM;
    textured_quad_texture_info.width                = textured_quad_image_data.w.(u32);
    textured_quad_texture_info.height               = textured_quad_image_data.h.(u32);
    textured_quad_texture_info.layer_count_or_depth = 1;
    textured_quad_texture_info.num_levels           = 1;
    textured_quad_texture_info.usage                = sdl.GPU_Texture_Usage_Flags.SAMPLER;
    textured_quad_texture := sdl.create_gpu_texture(device, *textured_quad_texture_info);
    sdl.set_gpu_texture_name(device, textured_quad_texture, "Lettuce Texture");

    textured_quad_buffer_transfer_info: sdl.GPU_Transfer_Buffer_Create_Info;
    textured_quad_buffer_transfer_info.usage = sdl.GPU_Transfer_Buffer_Usage.UPLOAD;
    textured_quad_buffer_transfer_info.size  = size_of(PositionTextureVertex) * 4 + size_of(u16) * 6;
    textured_quad_buffer_transfer_buffer := sdl.create_gpu_transfer_buffer(device, *textured_quad_buffer_transfer_info);
    transfer_data := cast(*PositionTextureVertex) sdl.map_gpu_transfer_buffer(device, textured_quad_buffer_transfer_buffer, false);
    transfer_data[0] = .{-1,  1, 0, 0, 0};
    transfer_data[1] = .{ 1,  1, 0, 1, 0};
    transfer_data[2] = .{ 1, -1, 0, 1, 1};
    transfer_data[3] = .{-1, -1, 0, 0, 1};
    index_data := cast(*u16) (transfer_data + 4);
    index_data[0] = 0;
    index_data[1] = 1;
    index_data[2] = 2;
    index_data[3] = 0;
    index_data[4] = 2;
    index_data[5] = 3;
    sdl.unmap_gpu_transfer_buffer(device, textured_quad_buffer_transfer_buffer);

    textured_quad_texture_transfer_buffer_info: sdl.GPU_Transfer_Buffer_Create_Info;
    textured_quad_texture_transfer_buffer_info.usage = sdl.GPU_Transfer_Buffer_Usage.UPLOAD;
    textured_quad_texture_transfer_buffer_info.size  = cast(u32) (textured_quad_image_data.w * textured_quad_image_data.h * 4);
    textured_quad_texture_transfer_buffer := sdl.create_gpu_transfer_buffer(device, *textured_quad_texture_transfer_buffer_info);
    texture_transfer_ptr := cast(*u8) sdl.map_gpu_transfer_buffer(device, textured_quad_texture_transfer_buffer, false);
    memcpy(texture_transfer_ptr, textured_quad_image_data.pixels, textured_quad_image_data.w * textured_quad_image_data.h * 4);
    sdl.unmap_gpu_transfer_buffer(device, textured_quad_texture_transfer_buffer);

    // Upload the buffers
    upload_cmd_buf: *sdl.GPU_Command_Buffer = sdl.acquire_gpu_command_buffer(device);
    copy_pass:      *sdl.GPU_Copy_Pass      = sdl.begin_gpu_copy_pass(upload_cmd_buf);
    vertex_buffer_location: sdl.GPU_Transfer_Buffer_Location;
    vertex_buffer_location.transfer_buffer  = textured_quad_buffer_transfer_buffer;
    vertex_buffer_location.offset           = 0;
    vertex_buffer_region: sdl.GPU_Buffer_Region;
    vertex_buffer_region.buffer             = textured_quad_vertex_buffer;
    vertex_buffer_region.offset             = 0;
    vertex_buffer_region.size               = size_of(PositionTextureVertex) * 4;
    sdl.upload_to_gpu_buffer(copy_pass, *vertex_buffer_location, *vertex_buffer_region, false);

    index_buffer_location: sdl.GPU_Transfer_Buffer_Location;
    index_buffer_location.transfer_buffer   = textured_quad_buffer_transfer_buffer;
    index_buffer_location.offset            = size_of(PositionTextureVertex) * 4;
    index_buffer_region: sdl.GPU_Buffer_Region;
    index_buffer_region.buffer              = textured_quad_index_buffer;
    index_buffer_region.offset              = 0;
    index_buffer_region.size                = size_of(u16) * 6;
    sdl.upload_to_gpu_buffer(copy_pass, *index_buffer_location, *index_buffer_region, false);

    texture_transfer_info: sdl.GPU_Texture_Transfer_Info;
    texture_transfer_info.transfer_buffer   = textured_quad_texture_transfer_buffer;
    texture_transfer_info.offset            = 0;
    texture_buffer_region: sdl.GPU_Texture_Region;
    texture_buffer_region.texture           = textured_quad_texture;
    texture_buffer_region.w                 = cast(u32) textured_quad_image_data.w;
    texture_buffer_region.h                 = cast(u32) textured_quad_image_data.h;
    texture_buffer_region.d                 = 1;
    sdl.upload_to_gpu_texture(copy_pass, *texture_transfer_info, *texture_buffer_region, false);

    sdl.end_gpu_copy_pass(copy_pass);
    sdl.submit_gpu_command_buffer(upload_cmd_buf);
    sdl.destroy_surface(textured_quad_image_data);
    sdl.release_gpu_transfer_buffer(device, textured_quad_buffer_transfer_buffer);
    sdl.release_gpu_transfer_buffer(device, textured_quad_texture_transfer_buffer);

    /*
    * Main loop
    */
    exit := false;
    while !exit {
        event: sdl.Event;
        while sdl.poll_event(*event) {
            if event.type == {
                case sdl.Event_Type.QUIT;
                    exit = true;
                case sdl.Event_Type.KEY_UP;
                    if event.key.key == sdl.Keycode.ESCAPE exit = true;
            }
        }

        cmdbuf := sdl.acquire_gpu_command_buffer(device);
        if cmdbuf == null {
            log_error("SDL_AcquireGPUCommandBuffer failed: %\n", to_string(sdl.get_error()));
            return;
        }

        swapchain_texture: *sdl.GPU_Texture;
        acquired := sdl.wait_and_acquire_gpu_swapchain_texture(cmdbuf, window, *swapchain_texture, null, null);
        assert(acquired);
        if swapchain_texture != null {
            color_target_info: sdl.GPU_Color_Target_Info;
            color_target_info.texture     = swapchain_texture;
            color_target_info.clear_color = sdl.F_Color.{0.3, 0.6, 0.5, 1.0};
            color_target_info.load_op     = sdl.GPU_Load_Op.CLEAR;
            color_target_info.store_op    = sdl.GPU_Store_Op.STORE;

            render_pass := sdl.begin_gpu_render_pass(cmdbuf, *color_target_info, 1, null);

            textured_quad_vertex_buffer_binding: sdl.GPU_Buffer_Binding;
            textured_quad_vertex_buffer_binding.buffer = textured_quad_vertex_buffer;
            textured_quad_vertex_buffer_binding.offset = 0;
            textured_quad_index_buffer_binding:  sdl.GPU_Buffer_Binding;
            textured_quad_index_buffer_binding.buffer  = textured_quad_index_buffer;
            textured_quad_index_buffer_binding.offset  = 0;
            textured_quad_texture_binding: sdl.GPU_Texture_Sampler_Binding;
            textured_quad_texture_binding.texture      = textured_quad_texture;
            textured_quad_texture_binding.sampler      = textured_quad_sampler;

            sdl.bind_gpu_graphics_pipeline(render_pass, textured_quad_pipeline);
            sdl.bind_gpu_vertex_buffers(render_pass, 0, *textured_quad_vertex_buffer_binding, 1);
            sdl.bind_gpu_index_buffer(render_pass, *textured_quad_index_buffer_binding, sdl.GPU_Index_Element_Size.SIZE_16BIT);
            sdl.bind_gpu_fragment_samplers(render_pass, 0, *textured_quad_texture_binding, 1);
            sdl.draw_gpu_indexed_primitives(render_pass, 6, 1, 0, 0, 0);

            sdl.end_gpu_render_pass(render_pass);
        }

        sdl.submit_gpu_command_buffer(cmdbuf);
    }

    sdl.release_gpu_graphics_pipeline(device, textured_quad_pipeline);
    sdl.destroy_window(window);
    sdl.quit();

    return;
}
