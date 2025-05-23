/*
 *
 * Tencent is pleased to support the open source community by making
 * Hippy available.
 *
 * Copyright (C) 2022 THL A29 Limited, a Tencent company.
 * All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 */

#include "driver/napi/jsc/jsc_try_catch.h"
#include "driver/napi/jsc/jsc_ctx.h"
#include "driver/napi/jsc/jsc_ctx_value.h"

namespace hippy {
inline namespace driver {
inline namespace napi {

using string_view = footstone::string_view;


JSCTryCatch::JSCTryCatch(bool enable, std::shared_ptr<Ctx> ctx)
: TryCatch(enable, ctx) {
  is_verbose_ = false;
}

JSCTryCatch::~JSCTryCatch() {
  if (HasCaught()) {
    if (is_rethrow_ || is_verbose_) {
      std::shared_ptr<JSCCtx> ctx = std::static_pointer_cast<JSCCtx>(ctx_);
      if (is_rethrow_) {
        ctx->SetExceptionHandled(false);
      } else {
        ctx->SetExceptionHandled(true);
      }
    }
  }
}

void JSCTryCatch::ReThrow() {
  is_rethrow_ = true;
}

bool JSCTryCatch::HasCaught() {
  if (enable_) {
    std::shared_ptr<JSCCtx> ctx = std::static_pointer_cast<JSCCtx>(ctx_);
    return !!ctx->GetException();
  }
  return false;
}

bool JSCTryCatch::CanContinue() {
  if (enable_) {
    std::shared_ptr<JSCCtx> ctx = std::static_pointer_cast<JSCCtx>(ctx_);
    return !ctx->GetException();
  }
  return true;
}

bool JSCTryCatch::HasTerminated() {
  if (enable_) {
    std::shared_ptr<JSCCtx> ctx = std::static_pointer_cast<JSCCtx>(ctx_);
    return !!ctx->GetException();
  }
  return false;
}

bool JSCTryCatch::IsVerbose() {
  return is_verbose_;
}

void JSCTryCatch::SetVerbose(bool is_verbose) {
  is_verbose_ = is_verbose;
}

std::shared_ptr<CtxValue> JSCTryCatch::Exception() {
  std::shared_ptr<JSCCtx> ctx = std::static_pointer_cast<JSCCtx>(ctx_);
  return ctx->GetException();
}

string_view JSCTryCatch::GetExceptionMessage() {
  if (enable_) {
    std::shared_ptr<JSCCtx> ctx = std::static_pointer_cast<JSCCtx>(ctx_);
    return ctx->GetExceptionMessage(ctx->GetException());
  }
  return "";
}

}
}
}
