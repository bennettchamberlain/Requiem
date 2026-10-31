# Idempotent grant pointer for the caller. Not a secret.
# one_user_id is the Connect reference string, handed back unchanged.
# variables: $one_user_id (str), $space_id (optional str), $platforms (array<str>)
select (
  insert OneGrant {
    owner := assert_exists(global current_person),
    one_user_id := <str>$one_user_id,
    space_id := <optional str>$space_id,
    platforms := <array<str>>$platforms,
    connected_at := datetime_of_statement(),
    revoked_at := {},
  }
  unless conflict on (.owner)
  else (
    update OneGrant set {
      one_user_id := <str>$one_user_id,
      space_id := <optional str>$space_id,
      platforms := <array<str>>$platforms,
      connected_at := datetime_of_statement(),
      revoked_at := {},
      updated_at := datetime_of_statement(),
    }
  )
) {
  id,
  one_user_id,
  space_id,
  platforms,
  connected_at,
  revoked_at,
};
