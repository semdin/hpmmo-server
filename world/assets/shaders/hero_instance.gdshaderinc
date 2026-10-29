// Per-hero colours (HeroAppearance.apply_look / apply_house_tint), shared by
// every hero shader in ONE order: Godot numbers instance uniforms by their
// position in each shader, and a mesh with two materials (an outfit's arms:
// cloth + skin) shares one slot buffer - with different orders the house
// colour landed in the skin tint and painted the hands red.
instance uniform vec3 skin_tint : source_color = vec3(1.0);
instance uniform vec3 house_color : source_color = vec3(0.5);
instance uniform vec3 hair_color : source_color = vec3(0.169, 0.114, 0.086);
instance uniform vec3 scalp_select = vec3(0.0);
instance uniform vec3 iris_color : source_color = vec3(0.435, 0.502, 0.533);
