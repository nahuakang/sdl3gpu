load_image_bmp :: (image_filename: string, desired_channels: s32) -> *sdl.Surface {
	result:    *sdl.Surface;
	format:    sdl.Pixel_Format;
	full_path: string;

	full_path = sprint("%/%", base_path, image_filename);
	result    = sdl.load_bmp(full_path.data);
	if result == null {
		log_error("Failed to load BMP: %\n", to_string(sdl.get_error()));
		return null;
	}

	if desired_channels == 4 {
		format = sdl.Pixel_Format.ABGR8888;
	} else {
		log_error("Unexpected desired_channels: %\n", desired_channels);
		sdl.destroy_surface(result);
		return null;
	}
	if result.format != format {
		next := sdl.convert_surface(result, format);
		sdl.destroy_surface(result);
		result = next;
	}

	return result;
}
