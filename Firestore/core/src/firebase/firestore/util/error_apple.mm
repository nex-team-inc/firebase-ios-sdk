/*
 * Copyright 2019 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "Firestore/core/src/firebase/firestore/util/error_apple.h"

#include "Firestore/core/include/firebase/firestore/firestore_errors.h"
#include "Firestore/core/src/firebase/firestore/util/hard_assert.h"
#include "Firestore/core/src/firebase/firestore/util/string_apple.h"

// NB: This is also declared in Firestore/Source/Public/FIRFirestoreErrors.h
// NOLINTNEXTLINE: public constant
FOUNDATION_EXPORT NSString* const FIRFirestoreErrorDomain =
    @"FIRFirestoreErrorDomain";

namespace firebase {
namespace firestore {
namespace util {

// Translates a set of error_code and error_msg to an NSError.
NSError* MakeNSError(const int64_t error_code,
                     const absl::string_view error_msg,
                     NSError* cause) {
  if (error_code == FirestoreErrorCode::Ok) {
    return nil;
  }

  NSMutableDictionary<NSString*, id>* user_info =
      [NSMutableDictionary dictionary];
  user_info[NSLocalizedDescriptionKey] = WrapNSString(error_msg);
  if (cause) {
    user_info[NSUnderlyingErrorKey] = cause;
  }

  return [NSError errorWithDomain:FIRFirestoreErrorDomain
                             code:static_cast<NSInteger>(error_code)
                         userInfo:user_info];
}

Status MakeStatus(NSError* error) {
  if (!error) {
    return Status::OK();
  }

  HARD_ASSERT(error.domain == FIRFirestoreErrorDomain,
              "Can only translate a Firestore error to a status");
  auto error_code = static_cast<int>(error.code);
  HARD_ASSERT(error_code >= FirestoreErrorCode::Cancelled &&
                  error_code <= FirestoreErrorCode::Unauthenticated,
              "Unknown error code");
  return Status{static_cast<FirestoreErrorCode>(error_code),
                MakeString(error.localizedDescription)};
}

using VoidErrorBlock = void (^)(NSError* _Nullable error);

util::StatusCallback MakeCallback(VoidErrorBlock _Nullable block) {
  if (block) {
    return [block](Status status) { block(MakeNSError(status)); };
  } else {
    return [](Status status) {};
  }
}

}  // namespace util
}  // namespace firestore
}  // namespace firebase