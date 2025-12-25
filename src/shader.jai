load_shader :: (
	device:                *sdl.GPU_Device,
	shader_filename:       string,
	sampler_count:         u32,
	uniform_buffer_count:  u32,
	storage_buffer_count:  u32,
	storage_texture_count: u32
) -> *sdl.GPU_Shader {
	stage: sdl.GPU_Shader_Stage;
	if contains(shader_filename, ".vert") {
		stage = sdl.GPU_Shader_Stage.VERTEX;
	} else if contains(shader_filename, ".frag") {
		stage = sdl.GPU_Shader_Stage.FRAGMENT;
	} else {
		log_error("Invalid shader stage\n");
		return null;
	}

	entrypoint: string;
	full_path:  string;
	backend_formats := sdl.get_gpu_shader_formats(device);
	format          := sdl.GPU_Shader_Format.INVALID;

	if backend_formats & sdl.GPU_Shader_Format.SPIRV {
		full_path  = sprint("%/%.spv", base_path, shader_filename);
		format     = sdl.GPU_Shader_Format.SPIRV;
		entrypoint = "main";
	} else if backend_formats & sdl.GPU_Shader_Format.MSL {
		full_path  = sprint("%/%.msl", base_path, shader_filename);
		format     = sdl.GPU_Shader_Format.MSL;
		entrypoint = "main0";
	} else if backend_formats & sdl.GPU_Shader_Format.DXIL {
		full_path  = sprint("%/%.dxil", base_path, shader_filename);
		format     = sdl.GPU_Shader_Format.DXIL;
		entrypoint = "main";
	} else {
		log_error("Unrecognized backend shader format\n");
		return null;
	}

	code, success := read_entire_file(full_path);
	if !success {
		log_error("Failed to read shader file %\n", full_path);
		return null;
	}

	shader_info: sdl.GPU_Shader_Create_Info = {
		code_size            = xx code.count,
		code                 = code.data,
		entry_point          = entrypoint.data,
		format               = format,
		stage                = stage,
		num_samplers         = sampler_count,
		num_uniform_buffers  = uniform_buffer_count,
		num_storage_buffers  = storage_buffer_count,
		num_storage_textures = storage_texture_count,
	};

	shader := sdl.create_gpu_shader(device, *shader_info);
	if shader == null {
		log_error("Failed to create shader\n");
		free(code.data);
		return null;
	}

	free(code.data);
	return shader;
}
