// Make rotation matrix for 2D usages, which is always a rotation around the z-axis
make_rotation_matrix4_2d :: (angle: float) -> Matrix4 {
    c := cos(angle);
    s := sin(angle);
    // |  c -s  0  0 |
    // |  s  c  0  0 |
    // |  0  0  1  0 |
    // |  0  0  0  1 |
    m := Matrix4_Identity;
    m._11 = c;
    m._12 = -s;
    m._21 = s;
    m._22 = c;
    return m;
}
