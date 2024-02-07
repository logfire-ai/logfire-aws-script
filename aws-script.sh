#!/bin/bash

os_name=$(uname)

echo "Select an option:"
echo "1) Setup logfire-aws-lambda for the first time"
echo "2) Add more subscription filter to existing logfire-aws-lambda"
read -r -p "Enter your choice (1 or 2): " choice

case $choice in
    1)
        echo "Setting up logfire-aws-lambda for the first time..."
        # Check if jq is installed
        echo
        echo "Checking if jq is installed"
        echo
        if ! command -v jq &> /dev/null; then
            echo "jq is not installed. Trying to install it."
            echo

            if [ "$os_name" == "Linux" ]; then
                sudo apt-get install jq
            elif [ "$os_name" == "Darwin" ]; then
                brew install jq
            fi

            if ! command -v jq &> /dev/null; then
                  echo "jq installation failed. Please install it manually and restart the setup"
                  echo
                  exit 1
            fi
        fi

        echo "Checking if AWS CLI is installed"
        echo
        # Check if AWS CLI is installed
        if ! aws --version > /dev/null 2>&1; then
            echo "AWS CLI is not installed. Trying to install it."
            echo

            if ! zip -v > /dev/null 2>&1; then
               echo "zip is not installed. Trying to install it."
               echo

               if [ "$os_name" == "Linux" ]; then
                 sudo apt install zip
               elif [ "$os_name" == "Darwin" ]; then
                 brew install zip
               fi
            fi

            if ! zip -v > /dev/null 2>&1; then
                echo "zip installation failed. Please install it manually and restart the setup"
                echo
                exit 1
            fi


            if [ "$os_name" == "Linux" ]; then
               curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"

               unzip awscliv2.zip

               sudo ./aws/install
             elif [ "$os_name" == "Darwin" ]; then
                curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"

                sudo installer -pkg AWSCLIV2.pkg -target /
            fi

            if ! aws --version > /dev/null 2>&1; then
              echo "AWS CLI installation failed. Please install it manually and restart the setup"
              echo
              exit 1
            fi
        fi

        echo "Checking if AWS CLI is configured"

        output=$(aws account list-regions 2>&1)

        # Check if the output contains "aws configure"
        if [[ $output == *"aws configure"* ]]; then
            echo
            echo "AWS is not configured. Running 'aws configure'."
            aws configure
        else
            echo
            echo "AWS is already configured."
            echo
            # Continue with your script
        fi

        log_group_names=()
        log_group_arns=()

        # Fetch log group names and ARNs
        while IFS=$'\t' read -r name arn; do
            log_group_names+=("$name")
            log_group_arns+=("$arn")
        done < <(aws logs describe-log-groups | jq -r '.logGroups[] | "\(.logGroupName)\t\(.arn)"')

        # Check if log groups are available
        if [ ${#log_group_arns[@]} -eq 0 ]; then
            echo "No log groups found."
            echo
            exit 1
        fi

        selected_log_groups=()

        # Check if log groups are available
        if [ ${#log_group_arns[@]} -eq 0 ]; then
            echo "No log groups found."
            echo
            exit 1
        fi

        # Enter IAM
        echo "Please enter your AWS IAM:"
        read -r iam
        echo

        # Enter LOGFIRE_SOURCE_TOKEN
        echo "Please enter your LOGFIRE SOURCE TOKEN:"
        read -r logfire_source_token
        echo

        # Create IAM role
        role_name="lambda-ex"
        assume_role_policy=$(
cat <<-EOF
  {
      "Version": "2012-10-17",
      "Statement": [{
          "Effect": "Allow",
          "Principal": {"Service": "lambda.amazonaws.com"},
          "Action": "sts:AssumeRole"
      }]
  }
EOF
        )

        aws iam create-role --role-name "$role_name" --assume-role-policy-document "$assume_role_policy"
        echo "Role created successfully."
        echo

        # Attach policy to role
        policy_arn="arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
        aws iam attach-role-policy --role-name "$role_name" --policy-arn "$policy_arn"
        echo "Policy attached successfully."
        echo

        # Download Logfire AWS SDK
        url="https://github.com/logfire-ai/logfire-aws-lambda/releases/latest/download/logfire-aws-lambda.zip"
        output_filename="logfire-aws-lambda.zip"
        curl -L "$url" -o "$output_filename"
        echo "SDK downloaded successfully: $output_filename"
        echo

        # Create AWS Lambda function
        function_name="logfire-aws-lambda"
        zip_file="fileb://logfire-aws-lambda.zip"
        runtime="nodejs20.x"
        handler="index.handler"
        role="arn:aws:iam::$iam:role/lambda-ex"
        environment_variables="Variables={LOGFIRE_SOURCE_TOKEN=$logfire_source_token}"

        lambda_function_arn=$(aws lambda create-function --function-name "$function_name" --zip-file "$zip_file" --runtime "$runtime" --handler "$handler" --role "$role" --environment "$environment_variables" | jq -r '.FunctionArn')
        echo "Lambda function created successfully."
        echo

        # Display log group names and ask user to select one
        echo "Available log group names:"
        echo
        select log_group_name in "${log_group_names[@]}"; do
            # Find the index of the selected name
            for i in "${!log_group_names[@]}"; do
                if [[ "${log_group_names[$i]}" = "${log_group_name}" ]]; then
                    index=$i
                    break
                fi
            done
            break
        done

        # Get the ARN for the selected log group
        log_group_arn="${log_group_arns[$index]}"

        # Add permission to lambda
        random_id=$(date +%s%N | sha256sum | head -c 20)
        statement_id="logfire-aws-lambda-${random_id}"
        principal="logs.amazonaws.com"
        action="lambda:InvokeFunction"
        source_arn="$log_group_arn"
        source_account="$iam"

        aws lambda add-permission --function-name "$function_name" --statement-id "$statement_id" --principal "$principal" --action "$action" --source-arn "$source_arn" --source-account "$source_account"
        echo "Permission added to Lambda function successfully."
        echo

        # Create subscription filter
        filter_name="logfire-aws-lambda-filter"
        filter_pattern=""

        aws logs put-subscription-filter --log-group-name "$log_group_name" --filter-name "$filter_name" --filter-pattern "$filter_pattern" --destination-arn "$lambda_function_arn"
        echo "Subscription filter created successfully."
        echo
        ;;
    2)
        echo "Add more subscription filters to existing logfire-aws-lambda function"

        echo "Please enter your AWS IAM:"
        read -r iam

        filter_name="logfire-aws-lambda-filter"
        filter_pattern=""

        log_group_names=()
        log_group_arns=()

        # Fetch log group names and ARNs
        while IFS=$'\t' read -r name arn; do
            log_group_names+=("$name")
            log_group_arns+=("$arn")
        done < <(aws logs describe-log-groups | jq -r '.logGroups[] | "\(.logGroupName)\t\(.arn)"')

        # Check if log groups are available
        if [ ${#log_group_arns[@]} -eq 0 ]; then
            echo "No log groups found."
            echo
            exit 1
        fi

        # List all Lambda functions and parse the output to find the ARN of "logfire-aws-lambda"
        lambda_function_info=$(aws lambda list-functions | jq -r '.Functions[] | select(.FunctionName == "logfire-aws-lambda")')

        # Check if the function exists
        if [ -z "$lambda_function_info" ]; then
            echo "Function 'logfire-aws-lambda' not found."
            exit 1
        fi

        # Extract the ARN from the function info
        lambda_function_arn=$(echo "$lambda_function_info" | jq -r '.FunctionArn')

        selected_log_groups=()

        # Allow user to select multiple log groups
        echo "Available log group names:"
        for i in "${!log_group_names[@]}"; do
            echo "$((i+1))) ${log_group_names[$i]}"
        done

        # Allow user to select multiple log groups
        echo "Available log group names (enter number to select, type 'done' to finish):"
        PS3="Select a log group number (or type 'done' to finish): "
        while true; do
            echo "Enter the number of the log group to select (or type 'done' to finish):"
            read -r user_input
            if [[ "$user_input" == "done" ]]; then
                break
            fi

            if [[ "$user_input" =~ ^[0-9]+$ ]] && [ "$user_input" -ge 1 ] && [ "$user_input" -le ${#log_group_names[@]} ]; then
                selected_log_groups+=("${log_group_names[$user_input-1]}")
                echo "Selected: ${log_group_names[$user_input-1]}"
            else
                echo "Invalid choice. Please try again."
            fi

            read -r -p "Add more? (type 'done' to finish, or press Enter to continue): " answer
            if [ "$answer" == "done" ]; then
                break
            fi
        done
        echo

        # Add permission to lambda
        function_name="logfire-aws-lambda"
        principal="logs.amazonaws.com"
        action="lambda:InvokeFunction"
        source_account="$iam"

        # Apply put-subscription-filter to each selected log group
        for log_group_name in "${selected_log_groups[@]}"; do
          # Find the ARN corresponding to the selected log group name
          for i in "${!log_group_names[@]}"; do
              if [[ "${log_group_names[$i]}" == "$log_group_name" ]]; then
                  source_arn="${log_group_arns[$i]}"
                  break
              fi
          done

          random_id=$(date +%s%N | sha256sum | head -c 20)
          statement_id="logfire-aws-lambda-${random_id}"

          aws lambda add-permission --function-name "$function_name" --statement-id "$statement_id" --principal "$principal" --action "$action" --source-arn "$source_arn" --source-account "$source_account"

          aws logs put-subscription-filter --log-group-name "$log_group_name" --filter-name "$filter_name" --filter-pattern "$filter_pattern" --destination-arn "$lambda_function_arn"
          echo "Subscription filter created for $log_group_name."
        done

        echo "Subscription filters created successfully."
        echo
        ;;
    *)
        echo "Invalid choice. Please enter 1 or 2."
        exit 1
        ;;
esac

