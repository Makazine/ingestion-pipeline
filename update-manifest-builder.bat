@echo off
REM update-manifest-builder.bat
REM Windows batch script to update Manifest Builder Lambda

setlocal enabledelayedexpansion

set FUNCTION_NAME=ndjson-parquet-sqs-ManifestBuilderFunction
set LAMBDA_FILE=app\lambda_manifest_builder.py
set BUILD_DIR=build\lambda
set ZIP_FILE=%BUILD_DIR%\manifest-builder.zip

echo [INFO] Updating Manifest Builder Lambda...

REM Step 1: Create build directory
if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"

REM Step 2: Package Lambda
echo [INFO] Packaging Lambda function...
cd app
powershell -Command "Compress-Archive -Path lambda_manifest_builder.py -DestinationPath ..\%ZIP_FILE% -Force"
cd ..

echo [SUCCESS] Package created: %ZIP_FILE%

REM Step 3: Update Lambda function
echo [INFO] Updating Lambda function: %FUNCTION_NAME%

aws lambda update-function-code ^
  --function-name %FUNCTION_NAME% ^
  --zip-file fileb://%ZIP_FILE% ^
  --output json > %TEMP%\lambda-update-result.json

echo [SUCCESS] Lambda updated!
type %TEMP%\lambda-update-result.json

REM Step 4: Wait for update to complete
echo [INFO] Waiting for update to complete...
timeout /t 3 /nobreak >nul

aws lambda wait function-updated ^
  --function-name %FUNCTION_NAME%

echo [SUCCESS] Update complete and function is ready!

REM Optional: Test
set /p TEST_NOW="Do you want to test the function? (yes/no): "

if /i "%TEST_NOW%"=="yes" (
    echo [INFO] Testing function with empty event...

    echo {"Records":[]} > %TEMP%\test-payload.json

    aws lambda invoke ^
      --function-name %FUNCTION_NAME% ^
      --payload file://%TEMP%\test-payload.json ^
      %TEMP%\test-response.json

    echo [INFO] Response:
    type %TEMP%\test-response.json
)

echo [DONE] Manifest Builder updated successfully!
pause
