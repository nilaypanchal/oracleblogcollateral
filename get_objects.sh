
usage()
{
  echo "get_objects.sh [ -o | --output  OUTPUT_DIR] [-v | --verbose ] [ -s | --silent ]  [ -x | --proxy PROXY ]-f URI_PATTERN -a AUTH_STRING|-n"
  echo "URI patterns can contain 0 or 1 wildcards (%u or %U)."
  echo "Each URI pattern must be prefaced with -f or --file"
}

download()
{
    # Do a HEAD first to check if the file is there so we don't download
    # the body of an HTTP response signaling a 404 or some other error
    curl_head="$1"

    # cURL GET command to run
    curl_get="$2"

    # Do the HEAD and get the response code
    resp=$( eval "$curl_head" )
    code=$( echo "$resp" |  tail -1 )

    # HEAD returned 200 OK, so download the file and move on
    if [[ "$code" == 200 ]]; then
      [[ "$verbose" == 1 ]] && echo "Downloading $full"
      eval "$curl_get"

      # Delimit the output to easily check the return code with tail
      echo ""
      echo "0"
      return
    fi

    echo ""
    echo "$code"
}

# Print the usage string if no args or if asking for help
if [[ "$#" == 0 ]]; then
  usage
fi

if [[ "$#" == 1 && "$1" == "help" || "$1" == "-h" || "$1" == "--help" ]]; then
  usage
fi

# Make sure cURL is installed and get its path
curl_path=$( which curl )
if [[ "$?" -ne 0 ]]; then
  echo "Error: curl is not in the path or is not installed."
  usage; exit 1
fi

declare -a objects=()
verbose=0
silent=0
auth=1

# Parse input args
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -f|--file)
          # Verify that the file string pattern is a URI
          if [[ "$2" == *"https://"* || "$2" == *"http://"* ]]; then
            objects+=("$2")
            shift
          else
            echo "Error: dumpfile specification must be a URI"
            usage
            exit 1
          fi
        ;;
        # Specify userpass ('username:password')
        -a|--auth) userpass="$2"
                   shift
        ;;
        -n|--no-auth) auth=0
        ;;
        # Specify a directory for output files
        -o|--output) outdir="$2"
                     shift
        ;;
        # Specify a verbose output
        -v|--verbose) verbose=1
        ;;
        # No output desired
        -s|--silent) silent=1
        ;;
        # Use HTTP proxy
        -x|--proxy) proxy="$2"
                    shift
        ;;
        *) echo "Unknown parameter passed: $1";
           usage
           exit 1
         ;;
    esac
    shift
done

# Need something to download
if [[ -z "${objects[@]}" ]]; then
  echo "Error: must provide one or more URIs as input"
  usage; exit 1
fi

# Show the input
[[ "$verbose" == 1 ]] && echo "Got object store files:""${objects[@]}"

# Need credentials to access
if [[ "$auth" == 1 ]]; then
  if [[ -z "$userpass" ]]; then
    echo "Error: must provide a user/pass for access to object store"\
    "or pass the -n or --no-auth option"
    usage; exit 1
  fi
  userpass=" -u ""'""$userpass""'"
fi

# Set default output directory
if [[ -z "$outdir" ]]; then
  outdir="$PWD"
fi

# If output dir is passed in, ensure that we can create the directory
if [[ -d "$outdir" ]]; then
  # Print info if requested
  if [[ "$verbose" == 1 ]]; then
    mkdir -p -v "$outdir"
  else
    mkdir -p "$outdir"
  fi

  if [[ "$?" -ne 0 ]]; then
    echo "Error: failed to create output directory"
    usage; exit 1
  fi
fi

if [[ ! -z "$proxy" ]]; then
  # Wrap the proxy in single quotes and add the -x flag for cURL
  proxy=" -x ""'""$proxy""'"
fi

# Tell cURL to be verbose, too
if [[ "$verbose" == 1 ]]; then
  curl_args="$curl_args"" --verbose "
fi

# Tell cURL to be silent, too
if [[ "$silent" == 1 ]]; then
  curl_args="$curl_args"" --silent "
fi

for object in "${objects[@]}"
do
  [[ "$verbose" == 1 ]] && echo "object=$object"
  # Lowercase all the substitions
  object=$( echo "$object" | sed 's/%U/%u/' )

  # Initialize wild card flag for this URI
  wcard=0

  # Loop through each pattern
  if [[ "$object" == *"%u"* ]]; then

    # We can only have 1 wildcard in a URI
    if [[ $( grep -o "%u" <<< "$object" | wc -l ) > 1 ]]; then
      echo "Error: multiple wildcards in single dumpfile"
      usage; exit 1
    fi

    wcard=1

    # Parse the URI so we can substitute the wildcard
    begin=$( echo "$object" | sed -E 's/(.*)%u.*/\1/' )
    end=$( echo "$object" | sed -E 's/.*%u(.*)/\1/' )

    [[ "$verbose" == 1 ]] && echo "Parsed wildcard: $begin %u $end"

    # Initialize variables for substitution/loop counting
    sub=1
    num=1

    # Try to get each substitution value until we hit 404 or other error
    while :
    do
      # Substitution string
      sub=$(printf "%02d" $num)

      # Full URI with substitution string
      full="$begin""$sub""$end"
      [[ "$verbose" == 1 ]] && echo "Transformed object=$full"

      # Object name
      obj_name=$( echo "$full" | rev | cut -d '/' -f1 | rev )

      # Do a HEAD first to check if the file is there so we don't download
      # the body of an HTTP response signaling a 404 or some other error
      curl_head="$curl_path"" -w '%{http_code}' ""$curl_args""$userpass""$proxy"" -I ""$full"

      # cURL command to run
      # -w is to check the http return code so we know when to break
      # the $curl_args relate to --verbose or other cURL-specific paramters
      # the userpass needs to be wrapped in single quotes
      # -X GET to download the files
      # $full is the full URI
      # -o specifies the output
      curl_get="$curl_path"" -w '%{http_code}' ""$curl_args""$userpass""$proxy"" -X GET ""$full"" -o ""$outdir""/""$obj_name"

      # Try to download the file
      ret=$( download "$curl_head" "$curl_get" | tail -1 )
      # If the attempt was unsuccessful, print and move onto the next URI pattern
      if [[ ! "$ret" == 0 ]]; then
        [[ "$verbose" == 1 ]] && echo "cURL returned $ret"
        break
      fi

      # Increase the substitution string value
      let num++

    done
  fi

  # URIs without substitution
  if [[ "$wcard" == 0 ]]; then

    # Complete URI
    full="$object"

    # Object name
    obj_name=$( echo "$full" | rev | cut -d '/' -f1 | rev )

    # Do a HEAD first to check if the file is there so we don't download
    # the body of an HTTP response signaling a 404 or some other error
    curl_head="$curl_path"" -w '%{http_code}' ""$curl_args""$userpass""$proxy"" -I ""$full"

    # cURL command to run
    # -w is to check the http return code so we know when to break
    # the $curl_args relate to --verbose or other cURL-specific paramters
    # the userpass needs to be wrapped in single quotes
    # -X GET to download the files
    # $full is the full URI
    # -o specifies the output
    curl_get="$curl_path"" -w '%{http_code}' ""$curl_args""$userpass""$proxy"" -X GET ""$full"" -o ""$outdir""/""$obj_name"

    # Try to download the file
    ret=$( download "$curl_head" "$curl_get" | tail -1 )
    # If the attempt was unsuccessful, print and move onto the next URI pattern
    if [[ ! "$ret" == 0 ]]; then
      [[ "$verbose" == 1 ]] && echo "cURL returned $ret"
    fi

    continue
  fi
done
