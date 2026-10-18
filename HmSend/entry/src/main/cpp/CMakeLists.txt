cmake_minimum_required(VERSION 3.5.0)
project(kuaitls)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(DEFINED ENV{OHOS_ARCH})
    set(OHOS_ARCH $ENV{OHOS_ARCH})
endif()
message(STATUS "kuaitls building for OHOS_ARCH=${OHOS_ARCH}")

# OpenSSL 预编译库（ohpm 包 @ohos-rs/openssl）
set(OPENSSL_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR}/../../../../oh_modules/@ohos-rs/openssl)
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} ${OPENSSL_ROOT_PATH})
find_package(OpenSSL REQUIRED)

add_library(kuaitls SHARED tls_server.cpp)

target_include_directories(kuaitls PRIVATE ${OPENSSL_INCLUDE_DIRS})

target_link_libraries(kuaitls PUBLIC
    libace_napi.z.so
    OpenSSL::SSL
    OpenSSL::Crypto
)
