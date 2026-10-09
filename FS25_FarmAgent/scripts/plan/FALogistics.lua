-- FALogistics: pure geometry for parking a tractor+trailer under a combine's pipe.
--
-- Works in the combine's local frame: z = forward, x = lateral (sign = pipe side).
-- Inputs come from FAGameAdapter (vehicle sizes, learned pipe offset); the result is a
-- point/heading for a vanilla GoTo job. No game API here, so it is unit-tested.
--
-- Lessons from the first in-game test:
--  * the target must be computed from the FULLY unfolded pipe (the folded/moving
--    discharge node sits next to the combine body -> tractor rammed the combine)
--  * the stopped tractor must keep clear of the header, which is wider than the body
--    (the vanilla AI collision check then refuses to move: "blocked by ... Heder")

FALogistics = {}

FALogistics.MARGIN = 1.0             -- free space between vehicles, metres
FALogistics.PIPE_INSIDE_MARGIN = 0.4 -- pipe end must stay this far inside the trailer edge
FALogistics.TRACTOR_FRONT = 4.0      -- tractor front ahead of its AI reference node

-- p = {
--   pipeX, pipeZ            pipe end (fully unfolded) in combine-local metres
--   bodyHalfWidth           combine body half width
--   headerHalfWidth         header half width (0 when unknown/none)
--   headerZMin              rear edge of the header in combine-local z (nil = header at the very front)
--   trailerHalfWidth, tractorHalfWidth
--   fillOffsetZ             trailer fill volume relative to the tractor AI node along its axis (negative = behind)
--   margin                  optional
-- }
-- Returns pose = { x, z, shift, clearance, obstacle } in combine-local metres, where x/z is
-- the point the tractor's AI node must reach (same heading as the combine), or nil, reason.
function FALogistics.computeUnderPipePose(p)
    local margin = p.margin or FALogistics.MARGIN
    local side = p.pipeX >= 0 and 1 or -1
    local reach = math.abs(p.pipeX)
    if reach < 1.0 then
        return nil, "pipe is not unfolded"
    end

    -- Tractor AI node ahead of the pipe so that the fill volume sits under the pipe end.
    local aiZ = p.pipeZ - (p.fillOffsetZ or 0)
    local tractorFrontZ = aiZ + FALogistics.TRACTOR_FRONT

    -- What the parked tractor+trailer stands next to: the body, and the header if the
    -- tractor's front reaches the header zone.
    local obstacleHalf, obstacle = p.bodyHalfWidth or 1.5, "combine body"
    local headerHalf = p.headerHalfWidth or 0
    local headerZMin = p.headerZMin or -math.huge
    if headerHalf > obstacleHalf and tractorFrontZ > headerZMin - 0.5 then
        obstacleHalf, obstacle = headerHalf, "header"
    end

    local vehicleHalf = math.max(p.trailerHalfWidth or 1.25, p.tractorHalfWidth or 1.25)
    local required = obstacleHalf + vehicleHalf + margin
    local maxShift = math.max(0, (p.trailerHalfWidth or 1.25) - FALogistics.PIPE_INSIDE_MARGIN)

    local shift = 0
    if reach < required then
        shift = required - reach
        if shift > maxShift then
            return nil, string.format("pipe reaches %.1f m but %.1f m is needed to keep %.1f m clear of the %s",
                reach, required - maxShift, margin, obstacle)
        end
    end
    local lateral = reach + shift
    return {
        x = side * lateral,
        z = aiZ,
        shift = shift,
        clearance = lateral - vehicleHalf - obstacleHalf,
        obstacle = obstacle,
    }
end
