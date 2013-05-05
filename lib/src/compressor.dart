part of bzip2;

class _Bzip2Compressor implements _Bzip2Coder {
  
  int _blockSizeFactor;
  bool _noMoreData = false;
  bool _isFirstStep = true;
  bool _isDone = false;
  
  List<int> _input = new List<int>(_MAX_BYTES_REQUIRED);
  int _inputSize = 0;
  
  BitBuffer _outputBuffer = new BitBuffer(_MAX_BYTES_REQUIRED);
  
  _Bzip2Crc _blockCrc = new _Bzip2Crc();
  _Bzip2CombinedCrc _fileCrc = new _Bzip2CombinedCrc();
  
  int _originPointer;
  List<bool> _inUse;
  List<bool> _inUse16;
  List<int> _symbols;
  int _alphaSize;
  List<List<int>> Lens = create2dList(_TABLE_COUNT_MAX, _MAX_ALPHA_SIZE);
  List<List<int>> Freqs = create2dList(_TABLE_COUNT_MAX, _MAX_ALPHA_SIZE);
  List<List<int>> Codes = create2dList(_TABLE_COUNT_MAX, _MAX_ALPHA_SIZE);
  List<int> selectors;
  int _tableCount = 2;
  int _selectorCount;

  
  _Bzip2Compressor(this._blockSizeFactor) {
    if (this._blockSizeFactor < 1 || this._blockSizeFactor > 9) {
      throw new ArgumentError("invalid block size factor");
    }
  }

  void writeByte(int byte) {
    _input[_inputSize] = byte;
    _inputSize++;
  }
  
  bool canProcess() {
    return !_isDone && (_noMoreData || _inputSize >= _blockSizeFactor * _BLOCK_SIZE_STEP);
  }
  
  void process() {
    List<int> _buffer;
    
    if (_isFirstStep) {
      _writeHeader();
      _isFirstStep = false;
    }
    
    if (_inputSize != 0) {
      _buffer = _readBlock();
      
      /* block header */
      _calculateBlockCrc(_buffer);
      _fileCrc.update(_blockCrc.getDigest());
      _writeBlockHeader();
      
      /* compress block */
      _buffer = _rleEncode1(_buffer);
      _buffer = _burrowsWheelerTransform(_buffer);
      _inUse = _calculateInUse(_buffer);
      _inUse16 = _calculateInUse16(_inUse);
      _symbols = _calculateSymbols(_inUse);
      _alphaSize = _getAlphaSize(_inUse);
      _buffer = _mtf8Encode(_buffer, _symbols);
      _buffer = _rleEncode2(_buffer);
      _createHuffmanTables(_buffer);
      _writeBlock(_buffer);      
    }
    
    if (_noMoreData) {
      _writeFooter();
      _isDone = true;
    }
  }
  
  List<int> readOutput() {
    List<int> output = new List<int>(_MAX_BYTES_REQUIRED);
    int outputSize = 0;
    
    while (_outputBuffer.bitCount() >= 8) {
      output[outputSize++] = _outputBuffer.readByte();
    }
    
    int remainingBits = _outputBuffer.bitCount();
    if (_isDone && remainingBits > 0) {
      int padding = 8 - remainingBits;
      output[outputSize++] = _outputBuffer.readBits(remainingBits) << padding;
    }
    
    output = output.sublist(0, outputSize);
    return output;
  }
  
  void setEndOfData() {
    _noMoreData = true;
  }
  
  List<int> _writeBlock(List<int> _buffer) {    
    _outputBuffer.writeBit(0); /* not randomized */
    
    /* write inUse information */
    _outputBuffer.writeBits(_originPointer, _ORIGIN_BIT_COUNT);
    for (int i = 0; i < 16; i++) {
      _outputBuffer.writeBit(_inUse16[i] ? 1 : 0);
    }
    for (int i = 0; i < 256; i++) {
      if (_inUse16[i >> 4]) {
        _outputBuffer.writeBit(_inUse[i] ? 1 : 0);
      }
    }
    
    _outputBuffer.writeBits(_tableCount, _TABLE_COUNT_BITS);
    _outputBuffer.writeBits(_selectorCount, _SELECTOR_COUNT_BITS);
    
    /* write table selectors */
    List<int> selectorsSymbols = new List<int>.generate(_TABLE_COUNT_MAX, (x)=>x);
    List<int> selectorsEncoded = _mtf8Encode(selectors, selectorsSymbols);
    
    for (int selectorCode in selectorsEncoded) {
      for (int i = 0; i < selectorCode; i++) {
        _outputBuffer.writeBit(1);
      }
      _outputBuffer.writeBit(0);
    }
    
    /* write huffman tables */
    for (int table = 0; table < _tableCount; table++) {
      int currentLevel = Lens[table][0];
      _outputBuffer.writeBits(currentLevel, _LEVEL_BITS);
      
      for (int i = 0; i < _alphaSize; i++) {
        int nextLevel = Lens[table][i];
        
        while (currentLevel < nextLevel) {
          _outputBuffer.writeBits(2, 2);
          currentLevel++;
        }
        while (currentLevel > nextLevel) {
          _outputBuffer.writeBits(3, 2);
          currentLevel--;
        }
        
        _outputBuffer.writeBit(0);
      }
    }
    
    /* write symbols */
    for (int group = 0, bufferIndex = 0; group < _selectorCount; group++) {
      int table = selectors[group];
      int groupSize = min(_GROUP_SIZE, _buffer.length - bufferIndex);
      
      for (int groupIndex = 0; groupIndex < groupSize; groupIndex++) {
        int symbol = _buffer[bufferIndex++];
        _outputBuffer.writeBits(Codes[table][symbol], Lens[table][symbol]);
      }
    }
  }
  
  void _writeHeader() {
    for (int byte in _BZIP_SIGNATURE) {
      _outputBuffer.writeByte(byte);
    }
    _outputBuffer.writeByte('0'.codeUnitAt(0) + _blockSizeFactor);
  }
  
  void _writeBlockHeader() {
    for (int byte in _BLOCK_SIGNATURE) {
      _outputBuffer.writeByte(byte);
    }
    _outputBuffer.writeBits(_blockCrc.getDigest(), 32);
  }
  
  void _writeCompressedBlock(List<int> buffer) {
    for (int byte in buffer) {
      _outputBuffer.writeByte(byte);
    }
  }
  
  void _calculateBlockCrc(List<int> block) {
    _blockCrc.reset();
    for (int symbol in block) {
      _blockCrc.updateByte(symbol);
    }
  }
  
  void _writeFooter() {
    for (int byte in _FINISH_SIGNATURE) {
      _outputBuffer.writeByte(byte);
    }
    _outputBuffer.writeBits(_fileCrc.getDigest(), 32);
  }
  
  List<int> _readBlock() {
    List<int> result =  _input.sublist(0, _inputSize);
    _inputSize = 0;
    return result;
  }
  
  List<int> _rleEncode1(List<int> block) {
    List<int> result = new List<int>(_MAX_BYTES_REQUIRED);
    int resultIndex = 0;
    int blockIndex = 0;
    while (blockIndex < block.length) {
      int runLength = 0;
      int currentByte = block[blockIndex];
      int maxRunLength = min(block.length - blockIndex, _RLE_MODE_REP_SIZE + 255);
      
      while (runLength < maxRunLength && block[blockIndex] == currentByte) {
        runLength++;
        blockIndex++;
      }
      
      for (int i = 0; i < min(runLength, _RLE_MODE_REP_SIZE); i++) {
        result[resultIndex++] = currentByte;
      }
      
      if (runLength >= _RLE_MODE_REP_SIZE) {
        result[resultIndex++] = runLength - _RLE_MODE_REP_SIZE;
      }
    }
    
    result = result.sublist(0, resultIndex);
    return result;
  }
  
  List<int> _burrowsWheelerTransform(List<int> _buffer) {
    List<int> y = _buffer.map((x) => x + 1).toList();
    String s = new String.fromCharCodes(y);
    SuffixArray suffixArray = new SuffixArray(s + s);
    List<int> sortedSuffixes = suffixArray.getSortedSuffixes();
    
    List<int> result = new List<int>(_buffer.length);
    int resultIndex = 0;
    
    for (int b in sortedSuffixes) {
      if (b < _buffer.length) {
        if (b == 0) {
          _originPointer = resultIndex;
        }
        result[resultIndex++] = _buffer[(b + _buffer.length - 1) % _buffer.length];
      }
    }
    
    return result;
  }
  
  List<bool> _calculateInUse(List<int> _buffer) {
    List<bool> inUse = new List<bool>.filled(256, false);
    for (int value in _buffer) {
      inUse[value] = true;
    }
    return inUse;
  }
  
  List<bool> _calculateInUse16(List<bool> inUse) {
    List<bool> inUse16 = new List<bool>.filled(16, false);
    for (int i = 0; i < 256; i++) {
      if (inUse[i]) {
        inUse16[i >> 4] = true;
      }
    }
    return inUse16;
  }
  
  int _getAlphaSize(List<bool> inUse) {
    int alphaSize = inUse.where((v) => v).length + 2;
    return alphaSize;
  }
  
  List<int> _calculateSymbols(List<bool> inUse) {
    List<int> symbols = new List<int>(256);
    int symbolIndex = 0;
    for (int i = 0; i < 256; i++) {
      if (inUse[i]) {
        symbols[symbolIndex++] = i;
      }
    }
    symbols = symbols.sublist(0, symbolIndex);
    return symbols;
  }
  
  List<int> _mtf8Encode(List<int> buffer, List<int> symbols) {
    List<int> result = new List<int>(buffer.length);
    List<int> mtf = new List<int>.from(symbols);
    
    for (int index = 0; index < buffer.length; index++) {
      int symbolIndex = mtf.indexOf(buffer[index]);
      
      for (int index = symbolIndex; index > 0; index--) {
        mtf[index] = mtf[index - 1];
      }
      mtf[0] = buffer[index];
      
      result[index] = symbolIndex;
    }
    
    return result;
  }

  List<int> _rleEncode2(List<int> buffer) {
    List<int> result = new List<int>(_MAX_BLOCK_SIZE + 2);
    int resultIndex = 0;
    int bufferIndex = 0;
    
    while (bufferIndex < buffer.length) {
      int runLength = 0;
      
      while (bufferIndex < buffer.length && buffer[bufferIndex] == 0) {
        runLength++;
        bufferIndex++;
      }
      
      if (runLength != 0) {
        while (runLength != 0) {
          runLength--;
          result[resultIndex++] = (runLength & 1);
          runLength >>= 1;
        }
      } else {
        int value = buffer[bufferIndex++] + 1;
        result[resultIndex++] = value;
      }
    }
    
    result[resultIndex++] = _alphaSize - 1;
    
    result = result.sublist(0, resultIndex);
    return result;
  }
  
  void _createHuffmanTables(List<int> _buffer) {
    int totalSymbolCount = 0;
    List<int> symbolCounts = new List<int>.filled(_MAX_ALPHA_SIZE, 0);
    for (int value in _buffer) {
      symbolCounts[value]++;
      totalSymbolCount++;
    }
    
    _tableCount = 2;
    _selectorCount = (totalSymbolCount + _GROUP_SIZE - 1) ~/ _GROUP_SIZE;
    
    selectors = new List<int>(_selectorCount);
    
    int remainingSymbols = totalSymbolCount;
    int groupStart = 0;
    for (int table = _tableCount - 1; table >= 0; table--) {
      int targetCount = remainingSymbols ~/ (table + 1);
      int groupEnd = groupStart;
      int currentCount = 0;
      while (currentCount < targetCount)
        currentCount += symbolCounts[groupEnd++];
      
      Lens[table] = new List<int>.generate(_alphaSize, (i) => (groupStart <= i &&
                                           i < groupEnd) ? 0 : 1);
      groupStart = groupEnd;
      remainingSymbols -= currentCount;
    }

    for (int pass = 0; pass < _HUFFMAN_PASSES; pass++) {
      for (int group = 0, bufferIndex = 0; group < _selectorCount; group++) {
        int groupSize = min(_GROUP_SIZE, _buffer.length - bufferIndex);
        List<int> groupSymbols = _buffer.sublist(bufferIndex, bufferIndex + groupSize);
        
        int bestTable = 0;
        int bestCost = 0xFFFFFFFF;
        
        for (int table = 0; table < _tableCount; table++) {
          int cost = 0;
          for (int symbol in groupSymbols) {
            cost += Lens[table][symbol];
          }
          if (cost < bestCost) {
            bestTable = table;
            bestCost = cost;
          }
        }
        
        selectors[group] = bestTable;
        
        for (int symbol in groupSymbols) {
          Freqs[bestTable][symbol]++;
        }
      }
      
      for (int table = 0; table < _tableCount; table++) {
        for (int i = 0; i < _alphaSize; i++) {
          if (Freqs[table][i] == 0)
            Freqs[table][i] = 1;
        }
        _HuffmanEncoder encoder = new _HuffmanEncoder(_alphaSize, _MAX_HUFFMAN_LEN_FOR_ENCODING);
        encoder.generate(Freqs[table], Codes[table], Lens[table]);
      }
    }
  }
}

List<List<int>> create2dList(int n, int m) {
  List<List<int>> result = new List<List<int>>.generate(n, (_) => new List<int>.filled(m, 0));
  return result;
}
