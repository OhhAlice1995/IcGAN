-- This file reads the dataset generated by generateEncoderDataset.lua and
-- trains an encoder net that learns to map an image X to a noise vector Z.
-- This version uses the conditioned information given by an encoder Y,
-- which, given an image X, returns the attribute information Y.

require 'image'
require 'nn'
require 'optim'
torch.setdefaulttensortype('torch.FloatTensor')

local function getParameters()
  local opt = {
        name = 'encoder_c_celeba_conditionY_v2',
        batchSize = 64,
        outputPath= '././checkpoints/',        -- path used to store the encoder network
        datasetPath = '././celebA/c_noTest_AnetY_generatedDataset/', -- folder where the dataset is stored (not the file itself)
        split = 0.66,           -- split between train and test (i.e 0.66 -> 66% train, 33% test)
        nConvLayers = 4,        -- # of convolutional layers on the net
        nf = 32,                -- #  of filters in hidden layer
        nEpochs = 15,           -- #  of epochs
        lr = 0.0001,            -- initial learning rate for adam
        beta1 = 0.1,            -- momentum term of adam
        display = 1,            -- display 1= train and test error, 2 = error + batches images, 0 = false
        gpu = 1                 -- gpu = 0 is CPU mode. gpu=X is GPU mode on GPU X
              
  }
  
  for k,v in pairs(opt) do opt[k] = tonumber(os.getenv(k)) or os.getenv(k) or opt[k] end
  
  if opt.display then require 'display' end
  
  return opt
end

local function readDataset(path)
-- There's expected to find in path a file named groundtruth.dmp
-- which contains the image paths / image tensors and Z and Y input vectors.
    local X
    local data = torch.load(path..'groundtruth.dmp')
    
    local Z = data.Z
    local Y = data.Y
    
    if data.storeAsTensor then
        X = data.X 
        assert(Z:size(1)==X:size(1) and Y:size(1)==X:size(1), "groundtruth.dmp is corrupted, number of images and Z and Y vectors is not equal. Create the dataset again.")
    else
        assert(Z:size(1)==#data.imNames and Y:size(1)==#data.imNames, "groundtruth.dmp is corrupted, number of images and Z and Y vectors is not equal. Create the dataset again.")
        
        -- Load images
        local tmp = image.load(data.relativePath..data.imNames[1])
        X = torch.Tensor(#data.imNames, data.imSize[1], data.imSize[2], data.imSize[3])
        X[{{1},{},{},{}}] = tmp
        
        for i=2,#data.imNames do
            X[{{i},{},{},{}}] = image.load(data.relativePath..data.imNames[i])
        end
    end

    return X, Z, Y
end

local function splitTrainTest(x, z, y, split)
    local xTrain, zTrain, yTrain, xTest, zTest, yTest
    
    local nSamples = x:size(1)
    local splitInd = torch.floor(split*nSamples)
    
    xTrain = x[{{1,splitInd},{},{},{}}]
    zTrain = z[{{1,splitInd},{},{},{}}]
    yTrain = y[{{1,splitInd},{}}]
    
    xTest = x[{{splitInd+1,nSamples},{},{},{}}]
    zTest = z[{{splitInd+1,nSamples},{},{},{}}]
    yTest = y[{{splitInd+1,nSamples},{}}]
    
    return xTrain, zTrain, yTrain, xTest, zTest, yTest
end

local function getEncoderVAE_GAN(sample, Ysz, nFiltersBase, outputSize, nConvLayers)
  -- Encoder architecture taken from Autoencoding beyond pixels using a learned similarity metric (VAE/GAN hybrid)
  -- Zsz: size of the output vector Z
  -- Ysz: size of the output vector Y
  
  -- Sample is used to know the dimensionality of the data. 
  -- For convolutional layers we are only interested in the third dimension (RGB or grayscale)
    local inputSize = sample:size(1)+Ysz
    local encoder = nn.Sequential()
    
    -- Need a parallel table to put different layers for X (conv layers) 
    -- and Y (none) before joining both inputs together.
    local pt = nn.ParallelTable()
    
    -- Replicate Y to match image dimensions
    local Yrepl = nn.Sequential()
        -- ny -> ny x im_x_sz (replicate 2nd dimension)
    Yrepl:add(nn.Replicate(sample:size(2),2,1))
    -- ny x 8 -> ny x im_x_sz x im_y_sz (replicate 3rd dimension)
    Yrepl:add(nn.Replicate(sample:size(3),3,2))
    
    -- Join X and Y
    pt:add(nn.Identity()) -- First input is an image X. We don't apply any change to it.
    pt:add(Yrepl)
    
    encoder:add(pt)
    encoder:add(nn.JoinTable(1,3))
    
    -- Assuming nFiltersBase = 64, nConvLayers = 3
    -- 1st Conv layer: 5×5 64 conv. ↓, BNorm, ReLU
    --           Data: 32x32 -> 16x16
    encoder:add(nn.SpatialConvolution(inputSize, nFiltersBase, 5, 5, 2, 2, 2, 2))
    encoder:add(nn.SpatialBatchNormalization(nFiltersBase))
    encoder:add(nn.ReLU(true))
    
    -- 2nd Conv layer: 5×5 128 conv. ↓, BNorm, ReLU
    --           Data: 16x16 -> 8x8
    -- 3rd Conv layer: 5×5 256 conv. ↓, BNorm, ReLU
    --           Data: 8x8 -> 4x4
    local nFilters = nFiltersBase
    for j=2,nConvLayers do
        encoder:add(nn.SpatialConvolution(nFilters, nFilters*2, 5, 5, 2, 2, 2, 2))
        encoder:add(nn.SpatialBatchNormalization(nFilters*2))
        encoder:add(nn.ReLU(true))
        nFilters = nFilters * 2
    end
    
     -- 4th FC layer: 2048 fully-connected
    --         Data: 4x4 -> 16
    encoder:add(nn.View(-1):setNumInputDims(3)) -- reshape data to 2d tensor (samples x the rest)
    -- Assuming squared images and conv layers configuration (kernel, stride and padding) is not changed:
    --nFilterFC = (imageSize/2^nConvLayers)²*nFiltersLastConvNet
    local inputFilterFC = (sample:size(2)/2^nConvLayers)^2*nFilters
    encoder:add(nn.Linear(inputFilterFC, inputFilterFC)) 
    encoder:add(nn.BatchNormalization(inputFilterFC))
    encoder:add(nn.ReLU(true))
    encoder:add(nn.Linear(inputFilterFC, outputSize))

    local criterion = nn.MSECriterion()
    
    return encoder, criterion
end

local function assignBatches(batchX, batchZ, batchY, x, z, y, batch, batchSize, shuffle)
    
    data_tm:reset(); data_tm:resume()
    
    batchX:copy(x:index(1, shuffle[{{batch,batch+batchSize-1}}]:long()))
    batchZ:copy(z:index(1, shuffle[{{batch,batch+batchSize-1}}]:long()))
    batchY:copy(y:index(1, shuffle[{{batch,batch+batchSize-1}}]:long()))
    
    data_tm:stop()
    
    return batchX, batchZ, batchY
end

local function displayConfig(disp, title)
    -- initialize error display configuration
    local errorData, errorDispConfig
    if disp then
        errorData = {}
        errorDispConfig =
          {
            title = 'Encoder error - ' .. title,
            win = 1,
            labels = {'Epoch', 'Train error', 'Test error'},
            ylabel = "Error",
            legend='always'
          }
    end
    return errorData, errorDispConfig
end

function main()

  local opt = getParameters()
  if opt.display then display = require 'display' end
  
  -- Set timers
  local epoch_tm = torch.Timer()
  local tm = torch.Timer()
  data_tm = torch.Timer()

  -- Read dataset
  local X, Z, Y
  X, Z, Y = readDataset(opt.datasetPath)
  
  -- Split train and test
  local xTrain, zTrain, yTrain, xTest, zTest, yTest
  -- z --> contain Z vectors    y --> contain Y vectors
  xTrain, zTrain, yTrain, xTest, zTest, yTest = splitTrainTest(X, Z, Y, opt.split)

  -- X: #samples x im3 x im2 x im1
  -- Z: #samples x 100 x 1 x 1 
  -- Y: #samples x ny
  
  -- Set network architecture
  local encoder, criterion = getEncoderVAE_GAN(xTrain[1], Y:size(2), opt.nf, zTrain:size(2), opt.nConvLayers)
 
  -- Initialize batches
  local batchX = torch.Tensor(opt.batchSize, xTrain:size(2), xTrain:size(3), xTrain:size(4))
  local batchZ = torch.Tensor(opt.batchSize, zTrain:size(2))
  local batchY = torch.Tensor(opt.batchSize, yTrain:size(2))
  
  -- Copy variables to GPU
  if opt.gpu > 0 then
     require 'cunn'
     cutorch.setDevice(opt.gpu)
     batchX = batchX:cuda();  batchZ = batchZ:cuda(); batchY = batchY:cuda();
     
     if pcall(require, 'cudnn') then
        require 'cudnn'
        cudnn.benchmark = true
        cudnn.convert(encoder, cudnn)
     end
     
     encoder:cuda()
     criterion:cuda()
  end
  
  local params, gradParams = encoder:getParameters() -- This has to be always done after cuda call
  
  -- Define optim (general optimizer)
  local errorTrain
  local errorTest
  local function optimFunction(params) -- This function needs to be declared here to avoid using global variables.
      -- reset gradients (gradients are always accumulated, to accommodat batch methods)
      gradParams:zero()
      local outputs = encoder:forward{batchX, batchY}
      errorTrain = criterion:forward(outputs, batchZ)
      local dloss_doutput = criterion:backward(outputs, batchZ)
      encoder:backward({batchX, batchY}, dloss_doutput)
      
      return errorTrain, gradParams
  end
  
  local optimState = {
     learningRate = opt.lr,
     beta1 = opt.beta1,
  }
  
  local nTrainSamples = xTrain:size(1)
  local nTestSamples = xTest:size(1)
  
  -- Initialize display configuration (if enabled)
  local errorData, errorDispConfig = displayConfig(opt.display, opt.name)
  paths.mkdir(opt.outputPath)
  
  -- Train network
  local batchIterations = 0 -- for display purposes only
  for epoch = 1, opt.nEpochs do
      epoch_tm:reset()
      local shuffle = torch.randperm(nTrainSamples)
      for batch = 1, nTrainSamples-opt.batchSize+1, opt.batchSize  do
          tm:reset()
          -- Assign batches
          --[[local splitInd = math.min(batch+opt.batchSize, nTrainSamples)
          batchX:copy(xTrain[{{batch,splitInd}}])
          batchY:copy(yTrain[{{batch,splitInd}}])--]]
          
          batchX, batchZ, batchY = assignBatches(batchX, batchZ, batchY, xTrain, zTrain, yTrain, batch, opt.batchSize, shuffle)
          
          if opt.display == 2 and batchIterations % 20 == 0 then
              display.image(image.toDisplayTensor(batchX,0,torch.round(math.sqrt(opt.batchSize))), {win=2, title='Train mini-batch'})
          end
          
          -- Update network
          optim.adam(optimFunction, params, optimState)
          
          -- Display train and test error
          if opt.display and batchIterations % 20 == 0 then
              -- Test error
              batchX, batchZ, batchY = assignBatches(batchX, batchZ, batchY, xTest, zTest, yTest, torch.random(1,nTestSamples-opt.batchSize+1), opt.batchSize, torch.randperm(nTestSamples))
              local outputs = encoder:forward{batchX, batchY}
              errorTest = criterion:forward(outputs, batchZ)
              table.insert(errorData,
              {
                batchIterations/math.ceil(nTrainSamples / opt.batchSize), -- x-axis
                errorTrain, -- y-axis for label1
                errorTest -- y-axis for label2
              })
              display.plot(errorData, errorDispConfig)
              if opt.display == 2 then
                  display.image(image.toDisplayTensor(batchX,0,torch.round(math.sqrt(opt.batchSize))), {win=3, title='Test mini-batch'})
              end
          end
          
          -- Verbose
          if ((batch-1) / opt.batchSize) % 1 == 0 then
             print(('Epoch: [%d][%4d / %4d]  Error (train): %.4f  Error (test): %.4f  '
                       .. '  Time: %.3f s  Data time: %.3f s'):format(
                     epoch, ((batch-1) / opt.batchSize),
                     math.ceil(nTrainSamples / opt.batchSize),
                     errorTrain and errorTrain or -1,
                     errorTest and errorTest or -1,
                     tm:time().real, data_tm:time().real))
         end
         batchIterations = batchIterations + 1
      end
      print(('End of epoch %d / %d \t Time Taken: %.3f s'):format(
            epoch, opt.nEpochs, epoch_tm:time().real))
            
      -- Store network
      torch.save(opt.outputPath .. opt.name .. '_' .. epoch .. 'epochs.t7', encoder:clearState())
      torch.save('checkpoints/' .. opt.name .. '_error.t7', errorData)
  end
  
end

main()