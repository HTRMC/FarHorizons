pub const c = @cImport({
    @cInclude("GLFW/glfw3.h");
});

pub const Window = c.GLFWwindow;
pub const Monitor = c.GLFWmonitor;
pub const VidMode = c.GLFWvidmode;

pub const GLFW_CLIENT_API = c.GLFW_CLIENT_API;
pub const GLFW_NO_API = c.GLFW_NO_API;
pub const GLFW_RESIZABLE = c.GLFW_RESIZABLE;
pub const GLFW_VISIBLE = c.GLFW_VISIBLE;
pub const GLFW_DECORATED = c.GLFW_DECORATED;
pub const GLFW_FOCUSED = c.GLFW_FOCUSED;
pub const GLFW_MAXIMIZED = c.GLFW_MAXIMIZED;

pub const GLFW_TRUE = c.GLFW_TRUE;
pub const GLFW_FALSE = c.GLFW_FALSE;

pub const init = c.glfwInit;
pub const terminate = c.glfwTerminate;
pub const windowHint = c.glfwWindowHint;
pub const createWindow = c.glfwCreateWindow;
pub const destroyWindow = c.glfwDestroyWindow;
pub const windowShouldClose = c.glfwWindowShouldClose;
pub const pollEvents = c.glfwPollEvents;
pub const getFramebufferSize = c.glfwGetFramebufferSize;
pub const waitEvents = c.glfwWaitEvents;
pub const setWindowShouldClose = c.glfwSetWindowShouldClose;
pub const getKey = c.glfwGetKey;
pub const setKeyCallback = c.glfwSetKeyCallback;
pub const setFramebufferSizeCallback = c.glfwSetFramebufferSizeCallback;
pub const setWindowUserPointer = c.glfwSetWindowUserPointer;
pub const getWindowUserPointer = c.glfwGetWindowUserPointer;
