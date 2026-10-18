def generate_shader_code(current_layer, previous_layer, channels_in, channels_out):
    passes_in = int(np.ceil(channels_in / 4))
    passes_out = int(np.ceil(channels_out / 4))

    if previous_layer.name == "input_layer":
        previous_layer.name = "LUMA"

    shader_code = ""
    for pass_idx in range(passes_out):
        if any(layer_name in current_layer.name for layer_name in ["conv2d_1", "conv2d_2", "conv2d_3", "conv2d_4"]):
            shader_code += f"//!DESC ArtCNN C4F{filters} ({current_layer.name.title().replace('_', '-')}-ReLU)\n" #-{pass_idx}
        elif "conv2d" in current_layer.name:
            shader_code += f"//!DESC ArtCNN C4F{filters} ({current_layer.name.title().replace('_', '-')})\n"
        else:
            shader_code += f"//!DESC ArtCNN C4F{filters} ({current_layer.name.title().replace('_', '-')})\n"

        shader_code += f"//!HOOK LUMA\n"

        if previous_layer.name == "LUMA":
            shader_code += f"//!BIND {previous_layer.name}\n"
        elif "add" in previous_layer.name:
            for i in range(passes_in):
                shader_code += f"//!BIND conv2d_{i}\n"
                shader_code += f"//!BIND conv2d_5_{i}\n"
        elif "conv2d" in current_layer.name:
            for i in range(passes_in):
                shader_code += f"//!BIND {previous_layer.name}_{i}\n"
        elif "depth" in current_layer.name:
            shader_code += f"//!BIND {previous_layer.name}_0\n"

        if "depth" in current_layer.name:
            shader_code += f"//!WIDTH LUMA.w 2.0 *\n"
            shader_code += f"//!HEIGHT LUMA.h 2.0 *\n"
        else:
            shader_code += f"//!SAVE {current_layer.name}_{pass_idx}\n"
            shader_code += f"//!WIDTH LUMA.w\n"
            shader_code += f"//!HEIGHT LUMA.h\n"

        shader_code += f"//!COMPONENTS 4\n"
        shader_code += f"//!WHEN OUTPUT.w LUMA.w / 1.3 > OUTPUT.h LUMA.h / 1.3 > *\n\n"
        shader_code += "vec4 hook() {\n"

        if "conv2d" in current_layer.name:
            biases = current_layer.get_weights()[1][pass_idx*4:(pass_idx+1)*4]
            biases_str = ", ".join(str(w) for w in biases.flatten())
            shader_code += f"    vec4 result = vec4({biases_str});\n"

            for z in range(passes_in):
                for y in range(-1, 2):
                    for x in range(-1, 2):
                        weights = current_layer.get_weights()[0][y+1, x+1, z*4:(z+1)*4, pass_idx*4:(pass_idx+1)*4]
                        weights_str = ", ".join(str(w) for w in weights.flatten())

                        if weights_str:
                            if previous_layer.name == "LUMA":
                                shader_code += f"    result += vec4({weights_str}) * {previous_layer.name}_texOff(vec2({x}, {y})).x;\n"
                            elif "add" in previous_layer.name:
                                shader_code += f"    result += mat4({weights_str}) * (conv2d_5_{z}_texOff(vec2({x}, {y})) + conv2d_{z}_texOff(vec2({x}, {y})));\n"
                            else:
                                shader_code += f"    result += mat4({weights_str}) * {previous_layer.name}_{z}_texOff(vec2({x}, {y}));\n"

            if any(layer_name in current_layer.name for layer_name in ["conv2d_1", "conv2d_2", "conv2d_3", "conv2d_4"]):
                shader_code += "    return max(result, vec4(0.0));\n"
            else:
                shader_code += "    return result;\n"

        elif "depth" in current_layer.name:
            shader_code += f"    vec4 result = vec4(0.0, 0.0, 0.0, 1.0);\n"
            shader_code += f"    vec2 f0 = fract({previous_layer.name}_0_pos * {previous_layer.name}_0_size);\n"
            shader_code += f"    ivec2 i0 = ivec2(f0 * vec2(2.0));\n"
            shader_code += f"    result.x = {previous_layer.name}_0_tex((vec2(0.5) - f0) * {previous_layer.name}_0_pt + {previous_layer.name}_0_pos)[i0.y * 2 + i0.x];\n"
            shader_code += f"    return clamp(result, 0.0, 1.0);\n"

        shader_code += "}\n\n"
    return shader_code