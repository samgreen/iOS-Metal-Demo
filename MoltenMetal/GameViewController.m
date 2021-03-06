

#import "GameViewController.h"

@import GLKit;
@import Metal;
@import simd;
@import QuartzCore.CAMetalLayer;

// The max number of command buffers in flight
static const NSUInteger MAX_CONCURRENT_COMMAND_BUFFERS = 3;
// Max API memory buffer size.
static const size_t MAX_BYTES_PER_FRAME = 1024 * 1024;

float cubeVertexData[216] = {
    // Data layout for each line below is:
    // positionX, positionY, positionZ,     normalX, normalY, normalZ,
    0.5, -0.5, 0.5,   0.0, -1.0,  0.0,
    -0.5, -0.5, 0.5,   0.0, -1.0, 0.0,
    -0.5, -0.5, -0.5,   0.0, -1.0,  0.0,
    0.5, -0.5, -0.5,  0.0, -1.0,  0.0,
    0.5, -0.5, 0.5,   0.0, -1.0,  0.0,
    -0.5, -0.5, -0.5,   0.0, -1.0,  0.0,
    
    0.5, 0.5, 0.5,    1.0, 0.0,  0.0,
    0.5, -0.5, 0.5,   1.0,  0.0,  0.0,
    0.5, -0.5, -0.5,  1.0,  0.0,  0.0,
    0.5, 0.5, -0.5,   1.0, 0.0,  0.0,
    0.5, 0.5, 0.5,    1.0, 0.0,  0.0,
    0.5, -0.5, -0.5,  1.0,  0.0,  0.0,
    
    -0.5, 0.5, 0.5,    0.0, 1.0,  0.0,
    0.5, 0.5, 0.5,    0.0, 1.0,  0.0,
    0.5, 0.5, -0.5,   0.0, 1.0,  0.0,
    -0.5, 0.5, -0.5,   0.0, 1.0,  0.0,
    -0.5, 0.5, 0.5,    0.0, 1.0,  0.0,
    0.5, 0.5, -0.5,   0.0, 1.0,  0.0,
    
    -0.5, -0.5, 0.5,  -1.0,  0.0, 0.0,
    -0.5, 0.5, 0.5,   -1.0, 0.0,  0.0,
    -0.5, 0.5, -0.5,  -1.0, 0.0,  0.0,
    -0.5, -0.5, -0.5,  -1.0,  0.0,  0.0,
    -0.5, -0.5, 0.5,  -1.0,  0.0, 0.0,
    -0.5, 0.5, -0.5,  -1.0, 0.0,  0.0,
    
    0.5, 0.5,  0.5,  0.0, 0.0,  1.0,
    -0.5, 0.5,  0.5,  0.0, 0.0,  1.0,
    -0.5, -0.5, 0.5,   0.0,  0.0, 1.0,
    -0.5, -0.5, 0.5,   0.0,  0.0, 1.0,
    0.5, -0.5, 0.5,   0.0,  0.0,  1.0,
    0.5, 0.5,  0.5,  0.0, 0.0,  1.0,
    
    0.5, -0.5, -0.5,  0.0,  0.0, -1.0,
    -0.5, -0.5, -0.5,   0.0,  0.0, -1.0,
    -0.5, 0.5, -0.5,  0.0, 0.0, -1.0,
    0.5, 0.5, -0.5,  0.0, 0.0, -1.0,
    0.5, -0.5, -0.5,  0.0,  0.0, -1.0,
    -0.5, 0.5, -0.5,  0.0, 0.0, -1.0
};

typedef struct
{
    GLKMatrix4 modelview_projection_matrix;
    GLKMatrix4 normal_matrix;
} uniforms_t;

@implementation GameViewController {
    // layer
    CAMetalLayer *_metalLayer;
    id <CAMetalDrawable> _currentDrawable;
    BOOL _layerSizeDidUpdate;
    MTLRenderPassDescriptor *_renderPassDescriptor;
    
    // controller
    CADisplayLink *_timer;
    BOOL _gameLoopPaused;
    dispatch_semaphore_t _inflight_semaphore;
    id <MTLBuffer> _dynamicConstantBuffer;
    uint8_t _constantDataBufferIndex;
    
    // renderer
    id <MTLDevice> _device;
    id <MTLCommandQueue> _commandQueue;
    id <MTLLibrary> _defaultLibrary;
    id <MTLRenderPipelineState> _pipelineState;
    id <MTLBuffer> _vertexBuffer;
    id <MTLDepthStencilState> _depthState;
    id <MTLTexture> _depthTex;
    id <MTLTexture> _msaaTex;
    
    // uniforms
    GLKMatrix4 _projectionMatrix;
    GLKMatrix4 _viewMatrix;
    uniforms_t _uniform_buffer;
    float _rotation;
}

- (void)dealloc {
    [_timer invalidate];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    _constantDataBufferIndex = 0;
    // Create a semaphore to ensure thread safety for the GPU
    _inflight_semaphore = dispatch_semaphore_create(MAX_CONCURRENT_COMMAND_BUFFERS);
    
    [self setupMetal];
    [self loadAssets];
    
    // Create a timer synchronized to the screen's refresh rate
    _timer = [CADisplayLink displayLinkWithTarget:self selector:@selector(gameloop)];
    [_timer addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)setupMetal {
    // Find a usable device
    _device = MTLCreateSystemDefaultDevice();
    
    // Create a new command queue
    _commandQueue = [_device newCommandQueue];
    
    // Load all the shader files with a metal file extension in the project
    _defaultLibrary = [_device newDefaultLibrary];
    
    // Setup metal layer and add as sub layer to view
    _metalLayer = [CAMetalLayer layer];
    _metalLayer.device = _device;
    _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    
    // Change this to NO if the compute encoder is used as the last pass on the drawable texture
    _metalLayer.framebufferOnly = YES;
    
    // Add metal layer to the views layer hierarchy
    _metalLayer.frame = self.view.layer.frame;
    [self.view.layer addSublayer:_metalLayer];
    self.view.contentScaleFactor = [UIScreen mainScreen].scale;
}

- (void)loadAssets {
    // Allocate one region of memory for the uniform (for shaders) buffer
    _dynamicConstantBuffer = [_device newBufferWithLength:MAX_BYTES_PER_FRAME options:0];
    _dynamicConstantBuffer.label = @"UniformBuffer";
    
    // Load the fragment shader from the library
    id <MTLFunction> fragmentProgram = [_defaultLibrary newFunctionWithName:@"lighting_fragment"];
    // Load the vertex shader from the library
    id <MTLFunction> vertexProgram = [_defaultLibrary newFunctionWithName:@"lighting_vertex"];
    
    // Setup the vertex buffers
    _vertexBuffer = [_device newBufferWithBytes:cubeVertexData
                                         length:sizeof(cubeVertexData)
                                        options:MTLResourceOptionCPUCacheModeDefault];
    _vertexBuffer.label = @"Vertices";
    
    // Create a reusable pipeline state
    MTLRenderPipelineDescriptor *pipelineStateDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineStateDescriptor.label = @"MyPipeline";
    pipelineStateDescriptor.sampleCount = 1;
    pipelineStateDescriptor.vertexFunction = vertexProgram;
    pipelineStateDescriptor.fragmentFunction = fragmentProgram;
    pipelineStateDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pipelineStateDescriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    
    NSError *error = NULL;
    _pipelineState = [_device newRenderPipelineStateWithDescriptor:pipelineStateDescriptor error:&error];
    if (!_pipelineState) {
        NSLog(@"Failed to created pipeline state, error %@", error);
    }
    
    MTLDepthStencilDescriptor *depthStateDesc = [[MTLDepthStencilDescriptor alloc] init];
    depthStateDesc.depthCompareFunction = MTLCompareFunctionLess;
    depthStateDesc.depthWriteEnabled = YES;
    _depthState = [_device newDepthStencilStateWithDescriptor:depthStateDesc];
}

- (void)setupRenderPassDescriptorForTexture:(id <MTLTexture>)texture {
    // Lazily load the render pass descriptor
    if (_renderPassDescriptor == nil)
        _renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    
    _renderPassDescriptor.colorAttachments[0].texture = texture;
    _renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    _renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.65f, 0.65f, 0.65f, 1.0f);
    _renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    
    [self setupDepthAttachmentForTexture:texture];
}

- (void)setupDepthAttachmentForTexture:(id <MTLTexture>)texture {
    //  If we need a depth texture and don't have one, or if the depth texture we have is the wrong size
    //  Then allocate one of the proper size
    if (!_depthTex || (_depthTex && (_depthTex.width != texture.width || _depthTex.height != texture.height))) {
        MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                        width:texture.width
                                                                                       height:texture.height
                                                                                    mipmapped:NO];
        _depthTex = [_device newTextureWithDescriptor:desc];
        _depthTex.label = @"Depth";
        
        _renderPassDescriptor.depthAttachment.texture = _depthTex;
        _renderPassDescriptor.depthAttachment.loadAction = MTLLoadActionClear;
        _renderPassDescriptor.depthAttachment.clearDepth = 1.0f;
        _renderPassDescriptor.depthAttachment.storeAction = MTLStoreActionDontCare;
    }
}

- (void)render {
    dispatch_semaphore_wait(_inflight_semaphore, DISPATCH_TIME_FOREVER);
    
    [self update];
    
    // Create a new command buffer for each renderpass to the current drawable
    id <MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    commandBuffer.label = @"MyCommand";
    
    // obtain a drawable texture for this render pass and set up the renderpass descriptor for the command encoder to render into
    id <CAMetalDrawable> drawable = [self currentDrawable];
    [self setupRenderPassDescriptorForTexture:drawable.texture];
    
    // Create a render command encoder so we can render into something
    id <MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:_renderPassDescriptor];
    renderEncoder.label = @"MyRenderEncoder";
    [renderEncoder setDepthStencilState:_depthState];
    
    // Set context state
    [renderEncoder pushDebugGroup:@"DrawCube"];
    // Set up pipeline state
    [renderEncoder setRenderPipelineState:_pipelineState];
    
    // Add the vertices to be passed on to the vertex shader
    [renderEncoder setVertexBuffer:_vertexBuffer offset:0 atIndex:0];
    [renderEncoder setVertexBuffer:_dynamicConstantBuffer offset:(sizeof(uniforms_t) * _constantDataBufferIndex) atIndex:1 ];
    
    // Draw out primitives
    [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:36 instanceCount:1];
    [renderEncoder popDebugGroup];
    
    // We're done. It's invalid to issue any more commands after we've ended encoding
    [renderEncoder endEncoding];
    
    // Call the view's completion handler which is required by the view since it will signal its semaphore and set up the next buffer
    __block dispatch_semaphore_t block_sema = _inflight_semaphore;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
        dispatch_semaphore_signal(block_sema);
    }];
    
    // The renderview assumes it can now increment the buffer index and that the previous index won't be touched until we cycle back around to the same index
    _constantDataBufferIndex = (_constantDataBufferIndex + 1) % MAX_CONCURRENT_COMMAND_BUFFERS;
    
    // Schedule a present once the framebuffer is complete
    [commandBuffer presentDrawable:drawable];
    // Finalize rendering here & push the command buffer to the GPU
    [commandBuffer commit];
}

- (void)reshape {
    // Update the view and projection matricies due to the view orientation or size changing
    float aspect = fabsf(self.view.bounds.size.width / self.view.bounds.size.height);
    _projectionMatrix = GLKMatrix4MakePerspective(65.f * (M_PI / 180.f), aspect, 0.1f, 100.f);
    _viewMatrix = GLKMatrix4Identity;
}

- (void)update {
    // Update our matrices
    GLKMatrix4 base_model = GLKMatrix4Multiply(GLKMatrix4MakeTranslation(0, 0, 5), GLKMatrix4MakeRotation(_rotation, 0, 1, 0));
    GLKMatrix4 base_mv = GLKMatrix4Multiply(_viewMatrix, base_model);
    GLKMatrix4 modelViewMatrix = GLKMatrix4Multiply(base_mv, GLKMatrix4MakeRotation(_rotation, 1, 1, 1));
    
    // Update the uniforms before passing them on to the shader
    _uniform_buffer.normal_matrix = GLKMatrix4Invert(GLKMatrix4Transpose(modelViewMatrix), NULL);
    _uniform_buffer.modelview_projection_matrix = GLKMatrix4Multiply(_projectionMatrix, modelViewMatrix);
    
    // Load constant buffer data into appropriate buffer at current index
    uint8_t *bufferPointer = (uint8_t *)[_dynamicConstantBuffer contents] + (sizeof(uniforms_t) * _constantDataBufferIndex);
    memcpy(bufferPointer, &_uniform_buffer, sizeof(uniforms_t));
    
    // Increment the rotation
    _rotation += 0.01f;
}

// The main game loop called by the CADisplayLink timer
- (void)gameloop {
    @autoreleasepool {
        if (_layerSizeDidUpdate) {
            CGSize drawableSize = self.view.bounds.size;
            drawableSize.width *= self.view.contentScaleFactor;
            drawableSize.height *= self.view.contentScaleFactor;
            _metalLayer.drawableSize = drawableSize;
            
            [self reshape];
            _layerSizeDidUpdate = NO;
        }
        
        // draw
        [self render];
        _currentDrawable = nil;
    }
}

// Called whenever view changes orientation or layout is changed
- (void)viewDidLayoutSubviews {
    _layerSizeDidUpdate = YES;
    _metalLayer.frame = self.view.layer.frame;
}

#pragma mark Utilities
- (id <CAMetalDrawable>)currentDrawable {
    // Keep synchronously asking the layer for a new drawable
    while (_currentDrawable == nil) {
        _currentDrawable = [_metalLayer nextDrawable];
        if (!_currentDrawable) {
            NSLog(@"[WARNING] CurrentDrawable is nil");
        }
    }
    return _currentDrawable;
}
@end
