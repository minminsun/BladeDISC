// Copyright 2022 The BladeDISC Authors. All rights reserved.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#ifndef DISC_TRANSFORM_OPS_EXT
#define DISC_TRANSFORM_OPS_EXT

include "mlir/Dialect/PDL/IR/PDLTypes.td"
include "mlir/Dialect/Transform/IR/TransformAttrs.td"
include "mlir/Dialect/Transform/IR/TransformDialect.td"
include "mlir/Dialect/Transform/IR/TransformInterfaces.td"
include "mlir/Interfaces/ControlFlowInterfaces.td"
include "mlir/Interfaces/SideEffectInterfaces.td"
include "mlir/IR/OpAsmInterface.td"
include "mlir/IR/OpBase.td"

def DISCBufferizeOp : Op<Transform_Dialect, "disc.bufferize",
    [FunctionalStyleTransformOpTrait,
     MemoryEffectsOpInterface,
     DeclareOpInterfaceMethods<TransformOpInterface>]> {
  let description = [{
    Target the whole module op and call upstream comprehensive bufferize with extra DISC hooks.

    Return modes:
    =============
    This operation calls the upstream one-shot bufferization pass with extra
    registered patterns for DISC.

    The pass is ran on all the ModuleOp nested under the top-level op on which
    the transform dialect interpreter pass is applied.

    If any of the pass on any of the ModuleOp fails, the transformation
    definitely fails. Otherwise the transformation succeeds.

    No handles are consumed or produced.
  }];

  let arguments = (ins PDL_Operation:$target);
  let results = (outs PDL_Operation:$result);

  let assemblyFormat = "attr-dict $target";
  let cppNamespace = "::mlir::disc_ral::transform_dialect";
}

def ApplyPatternsOp : Op<Transform_Dialect, "disc.apply_patterns",
    [FunctionalStyleTransformOpTrait,
     MemoryEffectsOpInterface,
     TransformEachOpTrait,
     TransformOpInterface]> {
  let description = [{
    Greedily applies patterns as specified by its attributes.

    Must be applied to an op with trait IsolatedFromAbove since the
    GreedyPatternRewriter asserts those.

    Returns the IsolatedFromAbove op whose content it has modified for better
    chaining APIs.

    The following additive attributes can be set, they add patterns in an
    unspecified order:
      - canonicalization: adds all the canonicalization patterns of all
      registered dialects and ops.

    Return modes:
    =============
    This operation applies a number of patterns to rewrite vector IR into
    distributed warp form. To apply these patterns, this operation must target
    an operation that is isolated from above, otherwise the transform definitely
    fails.

    If the pattern application fails, or if the underlying listener fails to
    capture op handles, the transformation definitely fails.

    Otherwise the transformation is successful and no result is returned.
  }];

  let arguments = (ins PDL_Operation:$target,
                       UnitAttr:$canonicalization);
  let results = (outs PDL_Operation:$result);

  let assemblyFormat = "$target attr-dict";
  let cppNamespace = "::mlir::disc_ral::transform_dialect";

  let builders = [
    // TODO: Some bitvector to scale better than n-bools.
    OpBuilder<(ins "Value":$target, "bool":$canonicalization)>
  ];

  let extraClassDeclaration = [{
    ::mlir::DiagnosedSilenceableFailure applyToOne(
        ::mlir::Operation *target,
        ::llvm::SmallVectorImpl<::mlir::Operation *> &results,
        ::mlir::transform::TransformState &state);
  }];
}

def FoldProducerExtractSliceOp : Op<Transform_Dialect, "disc.fold_producer_extract_slice",
    [FunctionalStyleTransformOpTrait,
     MemoryEffectsOpInterface,
     TransformEachOpTrait,
     TransformOpInterface]> {
  let description = [{
    Given a tensor.ExtractSliceOp, greedily fold its producers if they are also tensor.ExtractSliceOp.

    Returns the folded new tensor.ExtractSliceOp.

    The following additive attributes can be set:
      - max_repeat_num: fold at most `max_repeat_num` times.

    Return modes:
    =============
    This operation try to fold two tensor.ExtractSliceOp with def-use relationship at most
    `max_repeat_num` times.
  }];

  let arguments = (ins PDL_Operation:$target,
                       I64Attr:$max_repeat_num);
  let results = (outs PDL_Operation:$result);

  let assemblyFormat = "$target attr-dict";
  let cppNamespace = "::mlir::disc_ral::transform_dialect";

  let builders = [
    OpBuilder<(ins "Value":$target, "int64_t":$max_repeat_num)>
  ];

  let extraClassDeclaration = [{
    ::mlir::DiagnosedSilenceableFailure applyToOne(
        ::mlir::Operation *target,
        ::llvm::SmallVectorImpl<::mlir::Operation *> &results,
        ::mlir::transform::TransformState &state);
  }];
}

def CacheReadOp : Op<Transform_Dialect, "disc.cache_read",
    [DeclareOpInterfaceMethods<MemoryEffectsOpInterface>,
     DeclareOpInterfaceMethods<TransformOpInterface>]> {
  let description = [{
    Given a target `tensor.ExtractSliceOp` named 's0', first tile and pack source of the `s0`,
    and then replace `s0` with a new `tensor.ExtractSliceOp` named `s1`. `s1` will read from
    the packed and tiled source to increase the cache hit ratio. the transformed source tensor
    will be placed right before the `anthor` op.

    Returns the new tensor.ExtractSliceOp.

    The following attributes need to be set:
      - tileLevels: please see the document of `disc_ral::disc_linalg_ext::MultiLevelPackOp`
      - tileSizes: please see the document of `disc_ral::disc_linalg_ext::MultiLevelPackOp`
      - permutation: please see the document of `disc_ral::disc_linalg_ext::MultiLevelPackOp`
      - padded (optional): indicates that the slice op is padded and target tile is the padded
        version.

    Example #0:
     convert from:
     ```
      for (i, j) {
        %0 = tensor.extract_slice %arg0[i, j][32, 32][1, 1] : tensor<256x256xf32> to tensor<32x32xf32>
        use(%0)
      }
     ```
     to:
     ```
      %0 = tensor.empty() : tensor<8x8x32x32xf32>
      %packed = disc_linalg_ext.multi_level_pack %arg0 with
          tile_levels = [1, 1] tile_sizes = [32, 32] permutation = [0, 3, 1, 3] into %0
          (tensor<256x256xf32> tensor<8x8x32x32xf32>) -> tensor<8x8x32x32xf32>
      for (i, j) {
        i', j' = f(i, j) // index mapping
        %0 = tensor.extract_slice %packed[i', j', 0, 0][1, 1, 32, 32][1, 1, 1, 1] : tensor<8x8x32x32xf32> to tensor<32x32xf32>
        use(%0)
      }
     ```

    Example #1:
     convert from:
     ```
      #map = affine_map<(d0)[s0] -> (-d0 + s0, 32)>
      %cst0 = arith.constant 0.000000e+00 : f32
      for (i, j) {
        %s0 = affine.min #map(%i)[%d0]
        %s1 = affine.min #map(%j)[%d1]
        %0 = tensor.extract_slice %arg0[i, j][%s0, %s1][1, 1] : tensor<?x?xf32> to tensor<?x?xf32>
        %1 = tensor.pad %0 low[0, 0] high[32, 32] {
        ^bb0(%arg12: index, %arg13: index):
          tensor.yield %cst0 : f32
        } : tensor<?x?xf32> to tensor<32x32xf32>
        use(%1)
      }
     ```
     to:
     ```
      %0 = tensor.empty() : tensor<?x?x32x32xf32>
      %packed = disc_linalg_ext.multi_level_pack %arg0 with
          %cst0 tile_levels = [1, 1] tile_sizes = [32, 32] permutation = [0, 3, 1, 3] into %0
          (tensor<?x?xf32> tensor<?x?x32x32xf32>) -> tensor<?x?x32x32xf32>
      for (i, j) {
        i', j' = f(i, j) // index mapping
        %0 = tensor.extract_slice %packed[i', j', 0, 0][1, 1, 32, 32][1, 1, 1, 1] : tensor<?x?x32x32xf32> to tensor<32x32xf32>
        use(%0)
      }
     ```
  }];

  let arguments = (ins PDL_Operation:$target,
                       PDL_Operation:$anchor,
                       I64ArrayAttr:$tile_levels,
                       I64ArrayAttr:$tile_sizes,
                       I64ArrayAttr:$permutation,
                       UnitAttr:$padded);
  let results = (outs PDL_Operation:$result);

  let assemblyFormat = [{
    attr-dict
    $target `at` $anchor `with`
    `tile_levels` `=` $tile_levels
    `tile_sizes` `=` $tile_sizes
    `permutation` `=` $permutation
  }];
  let cppNamespace = "::mlir::disc_ral::transform_dialect";

  let builders = [
    OpBuilder<(ins "Value":$target, "Value":$anchor,
                   "ArrayRef<int64_t>":$tileLevels,
                   "ArrayRef<int64_t>":$tileSizes,
                   CArg<"bool", "false">:$padded,
                   CArg<"ArrayRef<int64_t>", "{}">:$permutation)>
  ];
}

def LowerMultiLevelPackToLoopOp : Op<Transform_Dialect, "disc.lower_multi_level_pack_to_loop",
    [FunctionalStyleTransformOpTrait,
     MemoryEffectsOpInterface,
     TransformEachOpTrait,
     TransformOpInterface]> {
  let description = [{
    Replace a MultiLevelPackOp to its loop level equivalent.

    Returns a handle to the outter most loop.
  }];

  let arguments = (ins PDL_Operation:$target);
  let results = (outs PDL_Operation:$result);

  let assemblyFormat = "$target attr-dict";
  let cppNamespace = "::mlir::disc_ral::transform_dialect";

  let builders = [
    OpBuilder<(ins "Value":$target)>
  ];

  let extraClassDeclaration = [{
    ::mlir::DiagnosedSilenceableFailure applyToOne(
        ::mlir::Operation *target,
        ::llvm::SmallVectorImpl<::mlir::Operation *> &results,
        ::mlir::transform::TransformState &state);
  }];
}

def InlineReductionInitializerOp : Op<Transform_Dialect, "disc.inline_reduction_initializer",
    [DeclareOpInterfaceMethods<MemoryEffectsOpInterface>,
     DeclareOpInterfaceMethods<TransformOpInterface>]> {
  let description = [{
    Given a buffer popluated by a reduction loop named `l0`, inline the initializer of the buffer
    into the loop `l0`.

    Returns the new xfer_read op.

    Example:
     convert from:
     ```
      linalg.fill ins(%cst : f32) outs(%0 : memref<?x?xf32>)
      scf.for %iv = %init to %stop step %step {
        %1 = memref.subview %0[...] : memref<?x?xf32> to memref<?x?xf32, strided<[?, 1], offset: 0>>
        %2 = vector.transfer_read %1[%c0, %c0], %cst : memref<?x?xf32, strided<[?, 1], offset: 0>>, vector<1x16xf32>
        use(%2)
      }
     ```
     to:
     ```
      %0 = memref.alloca() : memref<1x16xf32>
      linalg.fill ins(%cst : f32) outs(%0 : memref<1x16xf32>)
      scf.for %iv = %init to %stop step %step {
        %1 = memref.subview %0[...] : memref<?x?xf32> to memref<?x?xf32, strided<[?, 1], offset: 0>>
        %first_step = arith.cmpi eq %iv, %init : i1
        %2 = scf.if %first_step -> memref<?x?xf32, strided<[?, 1], offset: ?>> {
          %cast = memref.cast %0 :  memref<1x16xf32> to memref<?x?xf32, strided<[?, 1], offset: ?>>
          scf.yield %cast : memref<?x?xf32, strided<[?, 1], offset: ?>>
        } else {
          %cast = memref.cast %1 :  memref<?x?xf32, strided<[?, 1], offset: 0>> to memref<?x?xf32, strided<[?, 1], offset: ?>>
          scf.yield %cast : memref<?x?xf32, strided<[?, 1], offset: ?>>
        }
        %3 = vector.transfer_read %2[%c0, %c0], %cst : memref<?x?xf32, strided<[?, 1], offset: 0>>, vector<1x16xf32>
        use(%3)
      }
     ```
  }];

  let arguments = (ins PDL_Operation:$initializer,
                       PDL_Operation:$loop,
                       PDL_Operation:$reader);
  let results = (outs PDL_Operation:$result);

  let assemblyFormat = [{
    attr-dict $initializer `for` `reader` $reader  `into` `loop` $loop
  }];
  let cppNamespace = "::mlir::disc_ral::transform_dialect";
}

def DecomposeVectorsOp : Op<Transform_Dialect, "disc.decompose_vectors",
    [FunctionalStyleTransformOpTrait,
     MemoryEffectsOpInterface,
     TransformEachOpTrait,
     TransformOpInterface]> {
  let description = [{
    Decompose vector ops and related vector transform_read/write ops into fine-grained-size vector ops.

    Without this decomposition, llvm backend will mis-allocate vector register for some vector ops
    with specific shape (e.g. 8x12xf32 failed to map to hardware register). This is a workaround for this.

    Examples:
     convert
      ```
       %0 = vector.transfer_read %arg0[..., %c0] : vector<8xf32>
       %1 = vector.transfer_read %arg1[..., %c0] : vector<8xf32>
       %2 = vector.transfer_read %arg2[..., %c0] : vector<8xf32>
       %3 = vector.fma %0, %1, %2 : vector<8xf32>
       vector.transfer_write %3, %arg2[..., %c0] : vector<8xf32>
      ```
     to:
      ```
       %0_0 = vector.transfer_read %arg0[..., %c0] : vector<4xf32>
       %0_1 = vector.transfer_read %arg0[..., %c4] : vector<4xf32>
       %1_0 = vector.transfer_read %arg1[..., %c0] : vector<4xf32>
       %1_1 = vector.transfer_read %arg1[..., %c4] : vector<4xf32>
       %2_0 = vector.transfer_read %arg2[..., %c0] : vector<4xf32>
       %2_1 = vector.transfer_read %arg2[..., %c4] : vector<4xf32>
       %3_0 = vector.fma %0_0, %1_0, %2_0 : vector<4xf32>
       %3_1 = vector.fma %0_1, %1_1, %2_1 : vector<4xf32>
       vector.transfer_write %3_0, %arg2[..., %c0] : vector<4xf32>
       vector.transfer_write %3_1, %arg2[..., %c4] : vector<4xf32>
      ```
  }];

  let arguments = (ins PDL_Operation:$target,
                       I64Attr:$vector_size);
  let results = (outs PDL_Operation:$result);

  let assemblyFormat = "$target attr-dict";
  let cppNamespace = "::mlir::disc_ral::transform_dialect";

  let builders = [
    OpBuilder<(ins "Value":$target, "int64_t":$vector_size)>
  ];

  let extraClassDeclaration = [{
    ::mlir::DiagnosedSilenceableFailure applyToOne(
        ::mlir::Operation *target,
        ::llvm::SmallVectorImpl<::mlir::Operation *> &results,
        ::mlir::transform::TransformState &state);
  }];
}

def LinalgFuseOperandOp : Op<Transform_Dialect, "disc.linalg.fuse_operand",
    [FunctionalStyleTransformOpTrait,
     MemoryEffectsOpInterface,
     TransformEachOpTrait,
     TransformOpInterface]> {
  let description = [{
    Given a linalg op, try to fuse its specified operand linalg op into it.

    Returns the fused linalg.

    Example use:
     convert
    ```
      %3 = linalg.generic {indexing_maps = [#map1, #map1, #map1], iterator_types = ["parallel", "parallel"]} ins(%0, %1 : tensor<?x768xf32>, tensor<?x768xf32>) outs(%2 : tensor<?x768xf32>) attrs =  {disc.device = "cpu", disc.transform.name = "subtract"} {
      ^bb0(%in: f32, %in_0: f32, %out: f32):
        %6 = arith.subf %in, %in_0 : f32
        linalg.yield %6 : f32
      } -> tensor<?x768xf32>
      %6 = linalg.generic {indexing_maps = [#map1, #map1, #map1], iterator_types = ["parallel", "parallel"]} ins(%3, %4 : tensor<?x768xf32>, tensor<?x768xf32>) outs(%5 : tensor<?x768xf32>) attrs =  {disc.device = "cpu", disc.transform.name = "multiply"} {
      ^bb0(%in: f32, %in_0: f32, %out: f32):
        %6 = arith.mulf %in, %in_0 : f32
        linalg.yield %6 : f32
      } -> tensor<?x768xf32>
    ```
     to
    ```
     %6 = linalg.generic {indexing_maps = [#map1, #map1, #map1, #map1], iterator_types = ["parallel", "parallel"]} ins(%0, %1, %3 : tensor<?x768xf32>, tensor<?x768xf32>, tensor<?x768xf32>) outs(%5 : tensor<?x768xf32>) attrs =  {disc.device = "cpu", disc.transform.name = "multiply"} {
     ^bb0(%in: f32, %in_0: f32, %in_1: f32, %out: f32):
       %6 = arith.subf %in, %in_0 : f32
       %7 = arith.mulf %6, %in_1 : f32
       linalg.yield %7 : f32
     } -> tensor<?x768xf32>
    ```

  }];

  let arguments = (ins PDL_Operation:$target,
                       I64Attr:$operand_idx);
  let results = (outs PDL_Operation:$result);

  let assemblyFormat = "$target attr-dict";
  let cppNamespace = "::mlir::disc_ral::transform_dialect";

  let builders = [
    OpBuilder<(ins "Value":$target, "int64_t":$operand_idx)>
  ];

  let extraClassDeclaration = [{
    ::mlir::DiagnosedSilenceableFailure applyToOne(
        ::mlir::Operation *target,
        ::llvm::SmallVectorImpl<::mlir::Operation *> &results,
        ::mlir::transform::TransformState &state);
  }];
}

def LinalgFuseProducersOp : Op<Transform_Dialect, "disc.linalg.fuse_producers",
    [DeclareOpInterfaceMethods<MemoryEffectsOpInterface>,
     DeclareOpInterfaceMethods<TransformOpInterface>]> {
  let description = [{
    Given a linalg op, try to recursively and greedily fuse its operands if they are
    produced by the given op set.

    Returns the fused linalg.

    Example use. Suppose we have the following payload IR:
    ```
      %3 = linalg.generic {indexing_maps = [#map1, #map1, #map1], iterator_types = ["parallel", "parallel"]} ins(%0, %1 : tensor<?x768xf32>, tensor<?x768xf32>) outs(%2 : tensor<?x768xf32>) attrs =  {disc.device = "cpu", disc.transform.name = "subtract"} {
      ^bb0(%in: f32, %in_0: f32, %out: f32):
        %6 = arith.subf %in, %in_0 : f32
        linalg.yield %6 : f32
      } -> tensor<?x768xf32>
      %6 = linalg.generic {indexing_maps = [#map1, #map1, #map1], iterator_types = ["parallel", "parallel"]} ins(%3, %4 : tensor<?x768xf32>, tensor<?x768xf32>) outs(%5 : tensor<?x768xf32>) attrs =  {disc.device = "cpu", disc.transform.name = "multiply"} {
      ^bb0(%in: f32, %in_0: f32, %out: f32):
        %6 = arith.mulf %in, %in_0 : f32
        linalg.yield %6 : f32
      } -> tensor<?x768xf32>
      %8 = linalg.generic {indexing_maps = [#map1, #map1, #map1], iterator_types = ["parallel", "parallel"]} ins(%6, %6 : tensor<?x768xf32>, tensor<?x768xf32>) outs(%7 : tensor<?x768xf32>) attrs =  {disc.device = "cpu", disc.transform.name = "add"} {
      ^bb0(%in: f32, %in_0: f32, %out: f32):
        %6 = arith.addf %in, %in_0 : f32
        linalg.yield %6 : f32
      } -> tensor<?x768xf32>
    ```
     and following transform IR:
    ```
     %0 = transform.structured.match attributes {disc.transform.name = "subtract"} in %arg0
     %1 = transform.structured.match attributes {disc.transform.name = "multiply"} in %arg0
     %2 = transform.structured.match attributes {disc.transform.name = "add"} in %arg0
     %3 = transform.disc.fuse_producers %0, %1 into %2
    ```
     finally we'll get the following transformed IR:
    ```
     %6 = linalg.generic {indexing_maps = [#map1, #map1, #map1, #map1], iterator_types = ["parallel", "parallel"]} ins(%0, %1, %3 : tensor<?x768xf32>, tensor<?x768xf32>, tensor<?x768xf32>) outs(%5 : tensor<?x768xf32>) attrs =  {disc.device = "cpu", disc.transform.name = "multiply"} {
     ^bb0(%in: f32, %in_0: f32, %in_1: f32, %out: f32):
       %6 = arith.subf %in, %in_0 : f32
       %7 = arith.mulf %6, %in_1 : f32
       %8 = arith.addf %7, %7 : f32
       linalg.yield %8 : f32
     } -> tensor<?x768xf32>
    ```

  }];

  let arguments = (ins PDL_Operation:$target,
                       Variadic<PDL_Operation>:$producers);
  let results = (outs PDL_Operation:$result);

  let assemblyFormat = "$target attr-dict";
  let assemblyFormat = [{
    attr-dict
    $producers `into` $target
  }];
  let cppNamespace = "::mlir::disc_ral::transform_dialect";
}

def ReplaceConstPaddingValueOp : Op<Transform_Dialect, "disc.replace_const_padding_value",
    [FunctionalStyleTransformOpTrait,
     MemoryEffectsOpInterface,
     TransformEachOpTrait,
     TransformOpInterface]> {
  let description = [{
    Given a tensor.PadOp, replace its padding content using `padding_value_placeholder`

    Returns the updated tensor.PadOp op.
  }];

  let arguments = (ins PDL_Operation:$target,
                       StrAttr:$mode);
  let results = (outs PDL_Operation:$result);

  let assemblyFormat = "$target attr-dict `mode` `(` $mode `)`";
  let cppNamespace = "::mlir::disc_ral::transform_dialect";

  let builders = [
    OpBuilder<(ins "Value":$target, "StringRef":$mode)>
  ];

  let extraClassDeclaration = [{
    ::mlir::DiagnosedSilenceableFailure applyToOne(
        ::mlir::Operation *target,
        ::llvm::SmallVectorImpl<::mlir::Operation *> &results,
        ::mlir::transform::TransformState &state);
  }];
}

def ConvertPaddingPlaceholderToConstOp : Op<Transform_Dialect, "disc.convert_padding_placeholder_to_const",
    [FunctionalStyleTransformOpTrait,
     MemoryEffectsOpInterface,
     TransformEachOpTrait,
     TransformOpInterface]> {
  let description = [{
    Given a `padding_value_placeholder` op, convert to arith.const (ignore its padding mode).

    Returns the result const op.
  }];

  let arguments = (ins PDL_Operation:$target);
  let results = (outs PDL_Operation:$result);

  let assemblyFormat = "$target attr-dict";
  let cppNamespace = "::mlir::disc_ral::transform_dialect";
  let extraClassDeclaration = [{
    ::mlir::DiagnosedSilenceableFailure applyToOne(
        ::mlir::Operation *target,
        ::llvm::SmallVectorImpl<::mlir::Operation *> &results,
        ::mlir::transform::TransformState &state);
  }];
}

def LinalgEagerlyBackwardInitTensorOp : Op<Transform_Dialect, "disc.linalg.eagerly_backward_init_tensor",
    [FunctionalStyleTransformOpTrait,
     MemoryEffectsOpInterface,
     TransformEachOpTrait,
     TransformOpInterface]> {
  let description = [{
    Given a linalg op `A`, eagerly backward its init tensor to its producers. The function of such primitive
    is to reuse underline buffer.

    Eamples:
    ```
      %0 = linalg.generic { indexing_maps = [#map1, #map1, #map1], iterator_types = ["parallel", "parallel"]}
        ins(%arg0, %arg1) outs(%arg2)
      %1 = linalg.generic { indexing_maps = [#map1, #map1, #map1], iterator_types = ["parallel", "parallel"]}
        ins(%0, %0) outs(%arg3)
    ```
    After conversion:
    ```
      %0 = linalg.generic { indexing_maps = [#map1, #map1], iterator_types = ["parallel", "parallel"]}
        ins(%arg0, %arg1) outs(%arg3) // Note here use the final output buffer directly
      %1 = linalg.generic { indexing_maps = [#map1], iterator_types = ["parallel", "parallel"]}
        ins() outs(%0) // Note here: we promote %0 to be an output operand (thus can be read + write).
    ```

    Returns the result const op.
  }];

  let arguments = (ins PDL_Operation:$target);
  let results = (outs PDL_Operation:$result);

  let assemblyFormat = "$target attr-dict";
  let cppNamespace = "::mlir::disc_ral::transform_dialect";
  let extraClassDeclaration = [{
    ::mlir::DiagnosedSilenceableFailure applyToOne(
        ::mlir::Operation *target,
        ::llvm::SmallVectorImpl<::mlir::Operation *> &results,
        ::mlir::transform::TransformState &state);
  }];
}

// mainly copied from mlir community, adding support to fuse through
// iter_args for normal scf.for ops.

def DISCFuseIntoContainingOp :
    Op<Transform_Dialect, "disc.fuse_into_containing_op",
      [DeclareOpInterfaceMethods<MemoryEffectsOpInterface>,
       DeclareOpInterfaceMethods<TransformOpInterface>]> {
  let description = [{Fuse a producer into a containing operation.}];

  let summary = [{
    Fuses the `producer_op` into the `containing_op`.
    Returns a handle to the fused ops.

    The producer is typically a slice of a tileable op (i.e., implements
    TilingInterface). In that case, this transform computes the accessed
    producer slice inside of the containing op ("tile and fuse"). Otherwise,
    the entire producer is cloned inside the containing op ("clone and fuse").

    The containing op handle must be associated with exactly one payload op. The
    producer op handle may be associated with multiple payload ops. This
    transform fuses producers one-by-one, always picking an unspecified producer
    that has at least one use inside the containing op among the
    producers.

    Note: If a producer has multiple uses inside the containing op, it is
    currently tiled and/or cloned multiple times into the containing op.
    TODO: Reuse already fused OpResults instead of tiling/cloning a second time
    when possible. Fuse producers according to a topological sorting to achieve
    the largest amount of reuse.

    #### Return modes

    If at least one producer could not be fused, this operation fails silently.
    This is the case when tiling fails or when no producer op could be found
    among the remaining producers that has at least one use within the
    containing op. I.e., "producers" that are not consumed within the containing
    op are rejected by this operation.

    This operation reads and frees the producer handle.
    This operation reads the containing op handle.
  }];

  let arguments = (ins PDL_Operation:$producer_op,
                       PDL_Operation:$containing_op);
  let results = (outs PDL_Operation:$fused_op);
  let assemblyFormat = "$producer_op `into` $containing_op attr-dict";
  let cppNamespace = "::mlir::disc_ral::transform_dialect";
}

def ReductionOutputFuseOp : Op<Transform_Dialect, "disc.reduction_output_fuse",
    [DeclareOpInterfaceMethods<MemoryEffectsOpInterface>,
     DeclareOpInterfaceMethods<TransformOpInterface>]> {
  let description = [{
    Given a linalg op, output fuse it into the reduction loop.

    Returns the fused linalg op and the new loop op.

    Example:
     convert from:
     ```
      %1 = scf.for %arg1 = %c0 to %c768 step %c512 iter_args(%arg0 = %0) -> (tensor<?x3072xf32>) {
        ...
        %t0 = tensor.extract_slice %arg0[0, 0] [...] [1, 1] : tensor<?x3072xf32> to tensor<?x3072xf32>
        %t1 = linalg.matmul {disc.transform.name = "dot_general"} ins(...) outs(%t0 : tensor<?x3072xf32>) -> tensor<?x3072xf32>
        %t2 = tensor.insert_slice %t1 into %arg0[0, 0] [...] [1, 1] : tensor<?x3072xf32> into tensor<?x3072xf32>
        scf.yield %t2 : tensor<?x3072xf32>
      }
      %3 = tensor.extract_slice %2[...] [...] [1, 1] : tensor<?x3072xf32> to tensor<?x3072xf32>
      %4 = linalg.generic {indexing_maps = [#map5, #map6, #map7, #map6], iterator_types = ["parallel", "parallel"]} ins(..., %1, ...) outs(%3 : tensor<?x3072xf32>) attrs =  {disc.device = "cpu", disc.trasform.name = "maximum"} {
      ^bb0(%in: f32, %in_5: f32, %in_6: f32, %out: f32):
        %12 = arith.addf %in_5, %in_6 : f32
        %13 = arith.maxf %in, %12 : f32
        linalg.yield %13 : f32
      } -> tensor<?x3072xf32>
      use(%4)
     ```
     to:
     ```
      %3 = tensor.extract_slice %2[...] [...] [1, 1] : tensor<?x3072xf32> to tensor<?x3072xf32>
      %1, %4 = scf.for %arg1 = %c0 to %c768 step %c512 iter_args(%arg0 = %0, %arg1 = %3) -> (tensor<?x3072xf32>, tensor<?x3072xf32>) {
        ...
        %t0 = tensor.extract_slice %arg0[0, 0] [...] [1, 1] : tensor<?x3072xf32> to tensor<?x3072xf32>
        %t1 = linalg.matmul {disc.transform.name = "dot_general"} ins(...) outs(%t0 : tensor<?x3072xf32>) -> tensor<?x3072xf32>
        %t2 = tensor.insert_slice %t1 into %arg0[0, 0] [...] [1, 1] : tensor<?x3072xf32> into tensor<?x3072xf32>
        %t3 = tensor.extract_slice %arg1[0, 0] [...] [1, 1] : tensor<?x3072xf32> to tensor<?x3072xf32>
        %pred = ... // is last iteration?
        %t4 = disc_linalg_ext.conditional_generic {indexing_maps = [#map5, #map6, #map7, #map6], iterator_types = ["parallel", "parallel"]} ins(%pred, ..., %t2, ...) outs(%t3 : tensor<?x3072xf32>) attrs {disc.device = "cpu", disc.transform.name = "maximum"} {
        ^bb0(%in: f32, %in_5: f32, %in_6: f32, %out: f32):
          %12 = arith.addf %in_5, %in_6 : f32
          %13 = arith.maxf %in, %12 : f32
          linalg.yield %13 : f32
        } -> tensor<?x3072xf32>
        scf.yield %t2, %t4 : tensor<?x3072xf32>, tensor<?x3072xf32>
      }
      use(%4)
     ```
  }];

  let arguments = (ins PDL_Operation:$target,
                       PDL_Operation:$loop);
  let results = (outs PDL_Operation:$tiled_target, PDL_Operation:$fused_loop);

  let assemblyFormat = [{
    attr-dict $target `into` $loop
  }];
  let cppNamespace = "::mlir::disc_ral::transform_dialect";
}

def ReductionInputFuseOp : Op<Transform_Dialect, "disc.reduction_input_fuse",
    [DeclareOpInterfaceMethods<MemoryEffectsOpInterface>,
     DeclareOpInterfaceMethods<TransformOpInterface>]> {
  let description = [{
    Given a linalg op, input fuse it into the reduction loop.

    Returns the fused linalg op and the new loop op.

    Example:
     convert from:
     ```
      %0 = linalg.fill(%init)
      %1 = scf.for %arg1 = %c0 to %c768 step %c512 iter_args(%arg0 = %0) -> (tensor<?x3072xf32>) {
        ...
        %t0 = tensor.extract_slice %arg0[0, 0] [...] [1, 1] : tensor<?x3072xf32> to tensor<?x3072xf32>
        %t1 = linalg.matmul {disc.transform.name = "dot_general"} ins(...) outs(%t0 : tensor<?x3072xf32>) -> tensor<?x3072xf32>
        %t2 = tensor.insert_slice %t1 into %arg0[0, 0] [...] [1, 1] : tensor<?x3072xf32> into tensor<?x3072xf32>
        scf.yield %t2 : tensor<?x3072xf32>
      }
      use(%0)
     ```
     to:
     ```
      %1 = scf.for %arg1 = %c0 to %c768 step %c512 iter_args(%arg0 = %0) -> (tensor<?x3072xf32>) {
        ...
        %pred = ... // is first iteration?
        %t0 = disc_linalg_ext.conditional_generic ins(%pred) outs(%arg0)
        %t1 = tensor.extract_slice %t0[0, 0] [...] [1, 1] : tensor<?x3072xf32> to tensor<?x3072xf32>
        %t2 = linalg.matmul {disc.transform.name = "dot_general"} ins(...) outs(%t1 : tensor<?x3072xf32>) -> tensor<?x3072xf32>
        %t3 = tensor.insert_slice %t2 into %arg0[0, 0] [...] [1, 1] : tensor<?x3072xf32> into tensor<?x3072xf32>
        scf.yield %t3 : tensor<?x3072xf32>
      }
      use(%0)
     ```
  }];

  let arguments = (ins PDL_Operation:$target,
                       PDL_Operation:$loop);
  let results = (outs PDL_Operation:$tiled_target, PDL_Operation:$fused_loop);

  let assemblyFormat = [{
    attr-dict $target `into` $loop
  }];
  let cppNamespace = "::mlir::disc_ral::transform_dialect";
}

#endif // DISC_TRANSFORM_OPS_EXT
