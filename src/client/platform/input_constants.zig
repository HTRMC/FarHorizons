// Input constants for GLFW - mirrors Minecraft's InputConstants

const glfw = @import("glfw");
const c = glfw.c;

// Cursor modes for glfwSetInputMode
pub const CURSOR = c.GLFW_CURSOR;
pub const CURSOR_NORMAL = c.GLFW_CURSOR_NORMAL;
pub const CURSOR_HIDDEN = c.GLFW_CURSOR_HIDDEN;
pub const CURSOR_DISABLED = c.GLFW_CURSOR_DISABLED;

// Raw mouse motion (if supported)
pub const RAW_MOUSE_MOTION = c.GLFW_RAW_MOUSE_MOTION;

// Mouse buttons
pub const MOUSE_BUTTON_LEFT = c.GLFW_MOUSE_BUTTON_LEFT;
pub const MOUSE_BUTTON_RIGHT = c.GLFW_MOUSE_BUTTON_RIGHT;
pub const MOUSE_BUTTON_MIDDLE = c.GLFW_MOUSE_BUTTON_MIDDLE;
pub const MOUSE_BUTTON_4 = c.GLFW_MOUSE_BUTTON_4;
pub const MOUSE_BUTTON_5 = c.GLFW_MOUSE_BUTTON_5;

// Key states
pub const PRESS = c.GLFW_PRESS;
pub const RELEASE = c.GLFW_RELEASE;
pub const REPEAT = c.GLFW_REPEAT;

// Modifier keys
pub const MOD_SHIFT = c.GLFW_MOD_SHIFT;
pub const MOD_CONTROL = c.GLFW_MOD_CONTROL;
pub const MOD_ALT = c.GLFW_MOD_ALT;
pub const MOD_SUPER = c.GLFW_MOD_SUPER;

// Common keys
pub const KEY_ESCAPE = c.GLFW_KEY_ESCAPE;
pub const KEY_ENTER = c.GLFW_KEY_ENTER;
pub const KEY_TAB = c.GLFW_KEY_TAB;
pub const KEY_BACKSPACE = c.GLFW_KEY_BACKSPACE;
pub const KEY_INSERT = c.GLFW_KEY_INSERT;
pub const KEY_DELETE = c.GLFW_KEY_DELETE;
pub const KEY_RIGHT = c.GLFW_KEY_RIGHT;
pub const KEY_LEFT = c.GLFW_KEY_LEFT;
pub const KEY_DOWN = c.GLFW_KEY_DOWN;
pub const KEY_UP = c.GLFW_KEY_UP;
pub const KEY_PAGE_UP = c.GLFW_KEY_PAGE_UP;
pub const KEY_PAGE_DOWN = c.GLFW_KEY_PAGE_DOWN;
pub const KEY_HOME = c.GLFW_KEY_HOME;
pub const KEY_END = c.GLFW_KEY_END;
pub const KEY_SPACE = c.GLFW_KEY_SPACE;

// Letter keys
pub const KEY_A = c.GLFW_KEY_A;
pub const KEY_B = c.GLFW_KEY_B;
pub const KEY_C = c.GLFW_KEY_C;
pub const KEY_D = c.GLFW_KEY_D;
pub const KEY_E = c.GLFW_KEY_E;
pub const KEY_F = c.GLFW_KEY_F;
pub const KEY_G = c.GLFW_KEY_G;
pub const KEY_H = c.GLFW_KEY_H;
pub const KEY_I = c.GLFW_KEY_I;
pub const KEY_J = c.GLFW_KEY_J;
pub const KEY_K = c.GLFW_KEY_K;
pub const KEY_L = c.GLFW_KEY_L;
pub const KEY_M = c.GLFW_KEY_M;
pub const KEY_N = c.GLFW_KEY_N;
pub const KEY_O = c.GLFW_KEY_O;
pub const KEY_P = c.GLFW_KEY_P;
pub const KEY_Q = c.GLFW_KEY_Q;
pub const KEY_R = c.GLFW_KEY_R;
pub const KEY_S = c.GLFW_KEY_S;
pub const KEY_T = c.GLFW_KEY_T;
pub const KEY_U = c.GLFW_KEY_U;
pub const KEY_V = c.GLFW_KEY_V;
pub const KEY_W = c.GLFW_KEY_W;
pub const KEY_X = c.GLFW_KEY_X;
pub const KEY_Y = c.GLFW_KEY_Y;
pub const KEY_Z = c.GLFW_KEY_Z;

// Number keys
pub const KEY_0 = c.GLFW_KEY_0;
pub const KEY_1 = c.GLFW_KEY_1;
pub const KEY_2 = c.GLFW_KEY_2;
pub const KEY_3 = c.GLFW_KEY_3;
pub const KEY_4 = c.GLFW_KEY_4;
pub const KEY_5 = c.GLFW_KEY_5;
pub const KEY_6 = c.GLFW_KEY_6;
pub const KEY_7 = c.GLFW_KEY_7;
pub const KEY_8 = c.GLFW_KEY_8;
pub const KEY_9 = c.GLFW_KEY_9;

// Function keys
pub const KEY_F1 = c.GLFW_KEY_F1;
pub const KEY_F2 = c.GLFW_KEY_F2;
pub const KEY_F3 = c.GLFW_KEY_F3;
pub const KEY_F4 = c.GLFW_KEY_F4;
pub const KEY_F5 = c.GLFW_KEY_F5;
pub const KEY_F6 = c.GLFW_KEY_F6;
pub const KEY_F7 = c.GLFW_KEY_F7;
pub const KEY_F8 = c.GLFW_KEY_F8;
pub const KEY_F9 = c.GLFW_KEY_F9;
pub const KEY_F10 = c.GLFW_KEY_F10;
pub const KEY_F11 = c.GLFW_KEY_F11;
pub const KEY_F12 = c.GLFW_KEY_F12;

// Modifier keys
pub const KEY_LEFT_SHIFT = c.GLFW_KEY_LEFT_SHIFT;
pub const KEY_LEFT_CONTROL = c.GLFW_KEY_LEFT_CONTROL;
pub const KEY_LEFT_ALT = c.GLFW_KEY_LEFT_ALT;
pub const KEY_LEFT_SUPER = c.GLFW_KEY_LEFT_SUPER;
pub const KEY_RIGHT_SHIFT = c.GLFW_KEY_RIGHT_SHIFT;
pub const KEY_RIGHT_CONTROL = c.GLFW_KEY_RIGHT_CONTROL;
pub const KEY_RIGHT_ALT = c.GLFW_KEY_RIGHT_ALT;
pub const KEY_RIGHT_SUPER = c.GLFW_KEY_RIGHT_SUPER;
